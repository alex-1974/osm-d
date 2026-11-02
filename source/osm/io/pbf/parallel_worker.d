/**
 * Package-internal bounded worker pool for whole-buffer PBF summary decoding.
 *
 * Jobs borrow immutable serialized Blob bytes from an input buffer whose
 * lifetime is owned by the caller of PbfParallelReader.readSummary. Each
 * worker owns one reusable PbfReaderWorkspace.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-02
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.parallel_worker;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : ThreadGroup;

import osm.io.pbf.blob : BlobView, decodeBlob;
import osm.io.pbf.decompress : BlobPayloadView;
import osm.io.pbf.dense_nodes : DenseNodeView;
import osm.io.pbf.error : PbfStatus;
import pbfNode = osm.io.pbf.node;
import osm.io.pbf.reader :
    PbfReadStatus,
    PbfReadSummary,
    PbfReaderWorkspace,
    decodeDataBlock,
    decodeReaderBlobPayload,
    fromPbfFailure;
import osm.io.pbf.relation : RelationView;
import osm.io.pbf.way : WayView;

package(osm):

struct ParallelBlockJob
{
    ulong sequence;
    size_t fileBlockOffset;
    const(ubyte)[] blob;
}

final class ParallelDecodePool
{
private:
    ParallelBlockJob[] slots;
    size_t head;
    size_t tail;
    size_t count;
    bool closed;

    Mutex mutex;
    Condition notEmpty;
    Condition notFull;

    ParallelWorkerResult[] results;
    ThreadGroup threads;
    bool joined;

public:
    this(size_t workerCount, size_t queueCapacity)
    {
        assert(workerCount != 0);
        assert(queueCapacity != 0);

        slots.length = queueCapacity;
        results.length = workerCount;
        mutex = new Mutex;
        notEmpty = new Condition(mutex);
        notFull = new Condition(mutex);
        threads = new ThreadGroup;

        try
        {
            foreach (workerIndex; 0 .. workerCount)
                threads.create(makeWorker(workerIndex));
        }
        catch (Throwable)
        {
            close();
            threads.joinAll(false);
            throw;
        }
    }

    bool push(ParallelBlockJob job)
    {
        synchronized (mutex)
        {
            while (count == slots.length && !closed)
                notFull.wait();

            if (closed)
                return false;

            slots[tail] = job;
            tail = (tail + 1) % slots.length;
            ++count;
            notEmpty.notify();
            return true;
        }
    }

    void close()
    {
        synchronized (mutex)
        {
            if (closed)
                return;

            closed = true;
            notEmpty.notifyAll();
            notFull.notifyAll();
        }
    }

    void join()
    {
        if (joined)
            return;

        close();
        threads.joinAll();
        joined = true;
    }

    bool earliestFailure(out PbfReadStatus failure) const
    {
        bool found;
        foreach (ref const result; results)
        {
            if (!result.hasFailure)
                continue;

            if (!found || isEarlier(result.failure, failure))
            {
                failure = result.failure;
                found = true;
            }
        }
        return found;
    }

    void reduce(ref PbfReadSummary summary) const
    {
        foreach (ref const result; results)
            addSummary(summary, result.summary);
    }

private:
    bool pop(out ParallelBlockJob job)
    {
        synchronized (mutex)
        {
            while (count == 0 && !closed)
                notEmpty.wait();

            if (count == 0)
            {
                job = ParallelBlockJob.init;
                return false;
            }

            job = slots[head];
            slots[head] = ParallelBlockJob.init;
            head = (head + 1) % slots.length;
            --count;
            notFull.notify();
            return true;
        }
    }

    void delegate() makeWorker(size_t workerIndex)
    {
        return delegate void()
        {
            try
            {
                PbfReaderWorkspace workspace;
                ParallelSummarySink sink;
                ParallelWorkerResult result;

                ParallelBlockJob job;
                while (pop(job))
                {
                    PbfStatus pbfStatus;
                    BlobView blob;
                    if (!decodeBlob(job.blob, blob, pbfStatus))
                    {
                        recordFailure(
                            result,
                            fromPbfFailure(
                                job.sequence,
                                job.fileBlockOffset,
                                pbfStatus));
                        continue;
                    }

                    BlobPayloadView payload;
                    if (!decodeReaderBlobPayload(
                            blob,
                            workspace,
                            payload,
                            pbfStatus))
                    {
                        recordFailure(
                            result,
                            fromPbfFailure(
                                job.sequence,
                                job.fileBlockOffset,
                                pbfStatus));
                        continue;
                    }

                    PbfReadSummary blockSummary;
                    PbfReadStatus readStatus;
                    if (!decodeDataBlock(
                            payload.bytes,
                            workspace,
                            sink,
                            blockSummary,
                            job.sequence,
                            job.fileBlockOffset,
                            readStatus))
                    {
                        recordFailure(result, readStatus);
                        continue;
                    }

                    addSummary(result.summary, blockSummary);
                }

                results[workerIndex] = result;
            }
            catch (Throwable)
            {
                close();
                throw;
            }
        };
    }
}

private struct ParallelWorkerResult
{
    PbfReadSummary summary;
    PbfReadStatus failure;
    bool hasFailure;
}

private struct ParallelSummarySink
{
    void putDenseNodeScalars(long, long, long) @safe nothrow @nogc {}
    void put(scope ref DenseNodeView) @safe nothrow @nogc {}
    void put(scope ref pbfNode.NodeView) @safe nothrow @nogc {}
    void put(scope ref WayView) @safe nothrow @nogc {}
    void put(scope ref RelationView) @safe nothrow @nogc {}
}

private void recordFailure(
    ref ParallelWorkerResult result,
    PbfReadStatus failure)
    @safe nothrow @nogc
{
    if (!result.hasFailure || isEarlier(failure, result.failure))
    {
        result.failure = failure;
        result.hasFailure = true;
    }
}

bool isEarlier(
    PbfReadStatus candidate,
    PbfReadStatus current)
    @safe pure nothrow @nogc
{
    if (candidate.blockSequence != current.blockSequence)
        return candidate.blockSequence < current.blockSequence;
    return candidate.blockOffset < current.blockOffset;
}

void addSummary(
    ref PbfReadSummary target,
    ref const PbfReadSummary source)
    @safe nothrow @nogc
{
    target.headerBlocks += source.headerBlocks;
    target.dataBlocks += source.dataBlocks;
    target.primitiveGroups += source.primitiveGroups;
    target.nodes += source.nodes;
    target.ways += source.ways;
    target.relations += source.relations;
    target.tags += source.tags;
}
