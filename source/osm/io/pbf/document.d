/**
 * Durable PBF document bridge between semantic OSM data and raw preservation.
 *
 * `PbfDocument.data` is format-independent and editable. `PbfHeader`
 * represents the known HeaderBlock semantics needed for a semantic PBF rewrite.
 * `PbfDocument.preservation` owns the exact original file and records whether
 * source content exists that the semantic writer must not silently erase.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.document;

import osm.model.owned : OwnedBytes, OwnedDataset, ownBytes;
import osm.raw.pbf : PbfPreservation;

/** Exact owned HeaderBBox semantics in nanodegrees. */
struct PbfHeaderBBox
{
    long left;
    long right;
    long top;
    long bottom;
}

/**
 * Known semantic HeaderBlock content.
 *
 * Feature strings retain occurrence order and duplicates because declarations
 * can carry codec/consumer capability meaning. Unknown optional declarations
 * may be present here as exact bytes, but the preservation state then prevents
 * semantic rewrite until those semantics are understood.
 *
 * `.init` is an empty header. Use `standard` for a new OSM 0.6 document.
 */
struct PbfHeader
{
    bool hasBBox;
    PbfHeaderBBox bbox;

    OwnedBytes[] requiredFeatures;
    OwnedBytes[] optionalFeatures;

    bool hasWritingProgram;
    OwnedBytes writingProgram;

    bool hasSource;
    OwnedBytes source;

    bool hasReplicationTimestamp;
    long replicationTimestamp;

    bool hasReplicationSequenceNumber;
    long replicationSequenceNumber;

    bool hasReplicationBaseUrl;
    OwnedBytes replicationBaseUrl;

    /** Header suitable for a newly-created ordinary OSM 0.6 PBF document. */
    static PbfHeader standard() @safe
    {
        PbfHeader result;
        result.requiredFeatures ~= ownBytes(
            cast(const(ubyte)[])"OsmSchema-V0.6");
        return result;
    }

    /** Duplicate mutable feature arrays; immutable byte strings may share. */
    PbfHeader deepCopy() const @safe
    {
        PbfHeader result = this;
        result.requiredFeatures = requiredFeatures.dup;
        result.optionalFeatures = optionalFeatures.dup;
        return result;
    }
}

/**
 * Editable semantic PBF document with explicit raw preservation state.
 *
 * Copying follows ordinary D array aliasing rules. Use `deepCopy` for an
 * independently mutable semantic/header snapshot. The exact raw source is
 * immutable and may be shared safely.
 */
struct PbfDocument
{
    PbfHeader header;
    OwnedDataset data;
    PbfPreservation preservation;

    /** Create a new semantic document with the standard OSM 0.6 header. */
    static PbfDocument create(OwnedDataset data = OwnedDataset.init) @safe
    {
        PbfDocument result;
        result.header = PbfHeader.standard();
        result.data = data;
        return result;
    }

    /** Duplicate all mutable semantic/header arrays. */
    PbfDocument deepCopy() const @safe
    {
        PbfDocument result = this;
        result.header = header.deepCopy();
        result.data = data.deepCopy();
        return result;
    }
}

unittest
{
    auto document = PbfDocument.create();
    assert(document.header.requiredFeatures.length == 1);
    assert(document.data.empty);
    assert(document.preservation.semanticRewriteSafe);
}
