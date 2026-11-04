/**
 * Loss-aware semantic OSMPBF writer.
 *
 * The writer serializes the durable M4 semantic document into ordinary PBF
 * blocks. It never merges unknown raw protobuf payload into edited semantic
 * output: if the preservation scan found source content that the owned model
 * cannot represent, semantic write fails explicitly. Exact original-source
 * reproduction is a separate operation.
 *
 * Semantic output deliberately uses regular Node messages, raw (uncompressed)
 * Blob payloads, coordinate granularity 1 nanodegree and date granularity
 * 1 millisecond. This makes the write path simple and exact; DenseNodes and
 * compression remain representation optimizations rather than semantic
 * requirements.
 *
 * This module serializes PBF bytes; it does not own filesystem, HTTP, range or
 * stream transport. Workspace consumers use `transport-d` for those I/O
 * concerns once its released package contract is available. See ADR 0019.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.writer;

import osm.io.pbf.document : PbfDocument, PbfHeader;
import osm.io.pbf.features :
    HeaderFeatureKind,
    classifyHeaderFeature;
import osm.io.pbf.limits :
    maxBlobHeaderSize,
    maxSerializedBlobSize,
    maxUncompressedBlobSize;
import osm.model.owned :
    OwnedBytes,
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedTag,
    OwnedWay,
    ownBytes;
import osm.util.checked : checkedSub;
import osm.view.element : ElementType, OsmId;
import osm.wire.writer :
    appendBigEndianU32,
    appendInt32Field,
    appendInt64Field,
    appendLengthDelimited,
    appendSInt64Field,
    appendVarint,
    appendVarintField;
import osm.wire.zigzag : encodeZigZag64;

/** High-level failure category for semantic PBF writing. */
enum PbfWriteError : ubyte
{
    none,
    /// Raw preservation state proves that semantic rewrite would lose content.
    rewriteUnsafe,
    /// Exact-source reproduction was requested without captured source bytes.
    noOriginalSource,
    /// Writer options violate the bounded PBF block contract.
    invalidOptions,
    /// Current semantic content requires a HeaderBlock feature not declared.
    missingRequiredFeature,
    /// A known HeaderBlock feature cannot be truthfully produced by this writer.
    unsupportedHeaderFeature,
    /// Header declares type/id sorting but current semantic arrays violate it.
    sortOrderViolation,
    /// A Way mixes references with and without LocationsOnWays coordinates.
    partialWayLocations,
    /// Delta coding would overflow signed 64-bit arithmetic.
    integerOverflow,
    /// A generated StringTable cannot be addressed by uint32 String IDs.
    stringTableTooLarge,
    /// One indivisible PBF payload exceeds the format's hard block limit.
    blockTooLarge,
}

/** Diagnostic from one PBF write operation. */
struct PbfWriteStatus
{
    PbfWriteError error = PbfWriteError.none;
    ElementType elementType;
    OsmId elementId;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == PbfWriteError.none;
    }
}

/** Optional semantic-writer controls. Zero values select documented defaults. */
struct PbfWriteOptions
{
    /**
     * Preferred uncompressed PrimitiveBlock payload size.
     *
     * Zero selects 8 MiB. A single large element may exceed this preference but
     * never the hard PBF limit.
     */
    size_t targetUncompressedBlockSize;
}

/**
 * Stateless loss-aware PBF writer.
 *
 * `.init` is ready to use. Both operations are transactional with respect to
 * `output`: failure leaves the caller's existing byte array unchanged.
 */
struct PbfWriter
{
    /**
     * Serialize current known semantic state.
     *
     * The operation fails when `document.preservation.semanticRewriteSafe` is
     * false. Legal protobuf representation may differ from the input: the
     * writer emits regular Nodes, canonical packed repeated scalars, a
     * deterministic per-block StringTable and raw Blob payloads.
     */
    bool write(
        ref const PbfDocument document,
        ref ubyte[] output,
        out PbfWriteStatus status,
        PbfWriteOptions options = PbfWriteOptions.init)
        @safe
    {
        status = PbfWriteStatus.init;

        if (!document.preservation.semanticRewriteSafe)
        {
            status.error = PbfWriteError.rewriteUnsafe;
            return false;
        }

        const target = effectiveTarget(options, status);
        if (!status.ok)
            return false;

        bool hasLocations;
        bool hasVisibility;
        if (!inspectDocument(
                document,
                hasLocations,
                hasVisibility,
                status))
        {
            return false;
        }

        // Required-feature negotiation is fail-closed. The writer never
        // silently repairs HeaderBlock declarations in an owned document.
        if (!hasRequiredFeature(
                document.header,
                "OsmSchema-V0.6") ||
            (hasLocations &&
             !hasRequiredFeature(
                 document.header,
                 "LocationsOnWays")) ||
            (hasVisibility &&
             !hasRequiredFeature(
                 document.header,
                 "HistoricalInformation")))
        {
            status.error = PbfWriteError.missingRequiredFeature;
            return false;
        }

        bool requiresTypeIdSort;
        if (!validateHeaderFeatures(
                document.header,
                requiresTypeIdSort,
                status))
        {
            return false;
        }

        if (requiresTypeIdSort &&
            !isTypeIdSorted(document))
        {
            status.error = PbfWriteError.sortOrderViolation;
            return false;
        }

        ubyte[] encoded;

        ubyte[] headerPayload = encodeHeader(document.header);
        if (!appendFileBlock(
                encoded,
                "OSMHeader",
                headerPayload,
                status))
        {
            return false;
        }

        if (!appendNodeBlocks(
                encoded,
                document.data.nodes,
                target,
                status))
        {
            return false;
        }

        if (!appendWayBlocks(
                encoded,
                document.data.ways,
                target,
                status))
        {
            return false;
        }

        if (!appendRelationBlocks(
                encoded,
                document.data.relations,
                target,
                status))
        {
            return false;
        }

        output = encoded;
        status = PbfWriteStatus.init;
        return true;
    }

    /**
     * Reproduce the exact captured source file.
     *
     * This operation ignores semantic edits by design. Its name and separate
     * contract make it impossible to confuse byte-identical source recovery
     * with serialization of the current owned model.
     */
    bool writeOriginalSource(
        ref const PbfDocument document,
        ref ubyte[] output,
        out PbfWriteStatus status)
        @safe
    {
        status = PbfWriteStatus.init;

        if (!document.preservation.hasSource)
        {
            status.error = PbfWriteError.noOriginalSource;
            return false;
        }

        ubyte[] encoded;
        encoded.length = document.preservation.source.bytes.length;
        encoded[] = document.preservation.source.bytes[];
        output = encoded;
        return true;
    }
}

private enum size_t defaultTargetBlockSize = 8 * 1024 * 1024;
private enum size_t initialChunkElements = 8192;

private size_t effectiveTarget(
    PbfWriteOptions options,
    ref PbfWriteStatus status)
    @safe pure nothrow @nogc
{
    const value = options.targetUncompressedBlockSize == 0
        ? defaultTargetBlockSize
        : options.targetUncompressedBlockSize;

    if (value == 0 || value >= maxUncompressedBlobSize)
    {
        status.error = PbfWriteError.invalidOptions;
        return 0;
    }

    return value;
}

private bool inspectDocument(
    ref const PbfDocument document,
    out bool hasLocations,
    out bool hasVisibility,
    ref PbfWriteStatus status)
    @safe pure nothrow @nogc
{
    hasLocations = false;
    hasVisibility = false;

    foreach (ref const node; document.data.nodes)
        hasVisibility = hasVisibility || node.metadata.hasVisibility;

    foreach (ref const way; document.data.ways)
    {
        hasVisibility = hasVisibility || way.metadata.hasVisibility;

        bool anyLocation;
        bool anyMissing;
        foreach (ref const node; way.nodes)
        {
            anyLocation = anyLocation || node.hasLocation;
            anyMissing = anyMissing || !node.hasLocation;
        }

        if (anyLocation && anyMissing)
        {
            status.error = PbfWriteError.partialWayLocations;
            status.elementType = ElementType.way;
            status.elementId = way.id;
            return false;
        }

        hasLocations = hasLocations || anyLocation;
    }

    foreach (ref const relation; document.data.relations)
        hasVisibility = hasVisibility || relation.metadata.hasVisibility;

    return true;
}

private bool validateHeaderFeatures(
    ref const PbfHeader header,
    out bool requiresTypeIdSort,
    ref PbfWriteStatus status)
    @safe pure nothrow @nogc
{
    requiresTypeIdSort = false;

    foreach (feature; header.requiredFeatures)
    {
        if (!validateOneFeature(feature, requiresTypeIdSort, status))
            return false;
    }

    foreach (feature; header.optionalFeatures)
    {
        if (!validateOneFeature(feature, requiresTypeIdSort, status))
            return false;
    }

    return true;
}

private bool validateOneFeature(
    OwnedBytes feature,
    ref bool requiresTypeIdSort,
    ref PbfWriteStatus status)
    @safe pure nothrow @nogc
{
    final switch (classifyHeaderFeature(feature))
    {
        case HeaderFeatureKind.unknown:
        case HeaderFeatureKind.sortGeographic:
            status.error = PbfWriteError.unsupportedHeaderFeature;
            return false;

        case HeaderFeatureKind.sortTypeThenId:
            requiresTypeIdSort = true;
            return true;

        case HeaderFeatureKind.osmSchemaV06:
        case HeaderFeatureKind.denseNodes:
        case HeaderFeatureKind.historicalInformation:
        case HeaderFeatureKind.locationsOnWays:
        case HeaderFeatureKind.hasMetadata:
        case HeaderFeatureKind.legacyTimestamp:
            return true;
    }
}

private bool isTypeIdSorted(ref const PbfDocument document)
    @safe pure nothrow @nogc
{
    return idsSorted(document.data.nodes) &&
           idsSorted(document.data.ways) &&
           idsSorted(document.data.relations);
}

private bool idsSorted(T)(scope const(T)[] values)
    @safe pure nothrow @nogc
{
    if (values.length < 2)
        return true;

    foreach (i; 1 .. values.length)
    {
        if (values[i - 1].id > values[i].id)
            return false;
    }
    return true;
}

private bool hasRequiredFeature(
    ref const PbfHeader header,
    string feature)
    @safe pure nothrow @nogc
{
    foreach (value; header.requiredFeatures)
    {
        if (equalsAscii(value, feature))
            return true;
    }

    return false;
}

private bool equalsAscii(scope const(ubyte)[] bytes, string value)
    @safe pure nothrow @nogc
{
    if (bytes.length != value.length)
        return false;

    foreach (i; 0 .. bytes.length)
    {
        if (bytes[i] != cast(ubyte)value[i])
            return false;
    }
    return true;
}

private ubyte[] encodeHeader(ref const PbfHeader header) @safe
{
    ubyte[] result;

    if (header.hasBBox)
    {
        ubyte[] bbox;
        appendSInt64Field(bbox, 1, header.bbox.left);
        appendSInt64Field(bbox, 2, header.bbox.right);
        appendSInt64Field(bbox, 3, header.bbox.top);
        appendSInt64Field(bbox, 4, header.bbox.bottom);
        appendLengthDelimited(result, 1, bbox);
    }

    foreach (feature; header.requiredFeatures)
        appendLengthDelimited(result, 4, feature);

    foreach (feature; header.optionalFeatures)
        appendLengthDelimited(result, 5, feature);

    if (header.hasWritingProgram)
        appendLengthDelimited(result, 16, header.writingProgram);

    if (header.hasSource)
        appendLengthDelimited(result, 17, header.source);

    if (header.hasReplicationTimestamp)
        appendInt64Field(result, 32, header.replicationTimestamp);

    if (header.hasReplicationSequenceNumber)
        appendInt64Field(result, 33, header.replicationSequenceNumber);

    if (header.hasReplicationBaseUrl)
        appendLengthDelimited(result, 34, header.replicationBaseUrl);

    return result;
}

private bool appendNodeBlocks(
    ref ubyte[] output,
    scope const(OwnedNode)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    size_t start;
    while (start < values.length)
    {
        const end = minSize(values.length, start + initialChunkElements);
        if (!appendNodeChunk(output, values[start .. end], target, status))
            return false;
        start = end;
    }
    return true;
}

private bool appendWayBlocks(
    ref ubyte[] output,
    scope const(OwnedWay)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    size_t start;
    while (start < values.length)
    {
        const end = minSize(values.length, start + initialChunkElements);
        if (!appendWayChunk(output, values[start .. end], target, status))
            return false;
        start = end;
    }
    return true;
}

private bool appendRelationBlocks(
    ref ubyte[] output,
    scope const(OwnedRelation)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    size_t start;
    while (start < values.length)
    {
        const end = minSize(values.length, start + initialChunkElements);
        if (!appendRelationChunk(
                output,
                values[start .. end],
                target,
                status))
        {
            return false;
        }
        start = end;
    }
    return true;
}

private bool appendNodeChunk(
    ref ubyte[] output,
    scope const(OwnedNode)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    ubyte[] payload;
    if (!buildNodeBlock(values, payload, status))
        return false;
    return appendAdaptiveNodeBlock(
        output, values, payload, target, status);
}

private bool appendWayChunk(
    ref ubyte[] output,
    scope const(OwnedWay)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    ubyte[] payload;
    if (!buildWayBlock(values, payload, status))
        return false;
    return appendAdaptiveWayBlock(
        output, values, payload, target, status);
}

private bool appendRelationChunk(
    ref ubyte[] output,
    scope const(OwnedRelation)[] values,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    ubyte[] payload;
    if (!buildRelationBlock(values, payload, status))
        return false;
    return appendAdaptiveRelationBlock(
        output, values, payload, target, status);
}

private bool appendAdaptiveNodeBlock(
    ref ubyte[] output,
    scope const(OwnedNode)[] values,
    ubyte[] payload,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    if (payload.length > target && values.length > 1)
    {
        const mid = values.length / 2;
        return appendNodeChunk(output, values[0 .. mid], target, status) &&
               appendNodeChunk(output, values[mid .. $], target, status);
    }

    if (payload.length >= maxUncompressedBlobSize)
    {
        status.error = PbfWriteError.blockTooLarge;
        status.elementType = ElementType.node;
        status.elementId = values.length == 0 ? 0 : values[0].id;
        return false;
    }

    return appendFileBlock(output, "OSMData", payload, status);
}

private bool appendAdaptiveWayBlock(
    ref ubyte[] output,
    scope const(OwnedWay)[] values,
    ubyte[] payload,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    if (payload.length > target && values.length > 1)
    {
        const mid = values.length / 2;
        return appendWayChunk(output, values[0 .. mid], target, status) &&
               appendWayChunk(output, values[mid .. $], target, status);
    }

    if (payload.length >= maxUncompressedBlobSize)
    {
        status.error = PbfWriteError.blockTooLarge;
        status.elementType = ElementType.way;
        status.elementId = values.length == 0 ? 0 : values[0].id;
        return false;
    }

    return appendFileBlock(output, "OSMData", payload, status);
}

private bool appendAdaptiveRelationBlock(
    ref ubyte[] output,
    scope const(OwnedRelation)[] values,
    ubyte[] payload,
    size_t target,
    ref PbfWriteStatus status)
    @safe
{
    if (payload.length > target && values.length > 1)
    {
        const mid = values.length / 2;
        return appendRelationChunk(
                   output, values[0 .. mid], target, status) &&
               appendRelationChunk(
                   output, values[mid .. $], target, status);
    }

    if (payload.length >= maxUncompressedBlobSize)
    {
        status.error = PbfWriteError.blockTooLarge;
        status.elementType = ElementType.relation;
        status.elementId = values.length == 0 ? 0 : values[0].id;
        return false;
    }

    return appendFileBlock(output, "OSMData", payload, status);
}

private bool buildNodeBlock(
    scope const(OwnedNode)[] values,
    out ubyte[] payload,
    ref PbfWriteStatus status)
    @safe
{
    StringTableBuilder table;
    table.initialize();

    foreach (ref const value; values)
        prepareStrings(table, value.metadata, value.tags);

    if (table.values.length > uint.max)
    {
        status.error = PbfWriteError.stringTableTooLarge;
        return false;
    }

    ubyte[] group;
    foreach (ref const value; values)
    {
        ubyte[] encoded;
        appendSInt64Field(encoded, 1, value.id);
        appendTags(encoded, value.tags, table);

        const info = encodeInfo(value.metadata, table);
        if (info.length != 0)
            appendLengthDelimited(encoded, 4, info);

        appendSInt64Field(
            encoded,
            8,
            value.location.latitudeNanodegrees);
        appendSInt64Field(
            encoded,
            9,
            value.location.longitudeNanodegrees);

        appendLengthDelimited(group, 1, encoded);
    }

    payload = encodePrimitiveBlock(table, group);
    return true;
}

private bool buildWayBlock(
    scope const(OwnedWay)[] values,
    out ubyte[] payload,
    ref PbfWriteStatus status)
    @safe
{
    StringTableBuilder table;
    table.initialize();

    foreach (ref const value; values)
        prepareStrings(table, value.metadata, value.tags);

    if (table.values.length > uint.max)
    {
        status.error = PbfWriteError.stringTableTooLarge;
        return false;
    }

    ubyte[] group;
    foreach (ref const value; values)
    {
        ubyte[] encoded;
        appendInt64Field(encoded, 1, value.id);
        appendTags(encoded, value.tags, table);

        const info = encodeInfo(value.metadata, table);
        if (info.length != 0)
            appendLengthDelimited(encoded, 4, info);

        ubyte[] refs;
        ubyte[] lats;
        ubyte[] lons;
        long previousId;
        long previousLat;
        long previousLon;

        bool withLocations =
            value.nodes.length != 0 && value.nodes[0].hasLocation;

        foreach (ref const node; value.nodes)
        {
            long delta;
            if (!checkedSub(node.id, previousId, delta))
            {
                status.error = PbfWriteError.integerOverflow;
                status.elementType = ElementType.way;
                status.elementId = value.id;
                return false;
            }
            appendVarint(refs, encodeZigZag64(delta));
            previousId = node.id;

            if (withLocations)
            {
                const lat = node.location.latitudeNanodegrees;
                const lon = node.location.longitudeNanodegrees;

                if (!checkedSub(lat, previousLat, delta))
                {
                    status.error = PbfWriteError.integerOverflow;
                    status.elementType = ElementType.way;
                    status.elementId = value.id;
                    return false;
                }
                appendVarint(lats, encodeZigZag64(delta));
                previousLat = lat;

                if (!checkedSub(lon, previousLon, delta))
                {
                    status.error = PbfWriteError.integerOverflow;
                    status.elementType = ElementType.way;
                    status.elementId = value.id;
                    return false;
                }
                appendVarint(lons, encodeZigZag64(delta));
                previousLon = lon;
            }
        }

        if (refs.length != 0)
            appendLengthDelimited(encoded, 8, refs);
        if (withLocations)
        {
            appendLengthDelimited(encoded, 9, lats);
            appendLengthDelimited(encoded, 10, lons);
        }

        appendLengthDelimited(group, 3, encoded);
    }

    payload = encodePrimitiveBlock(table, group);
    return true;
}

private bool buildRelationBlock(
    scope const(OwnedRelation)[] values,
    out ubyte[] payload,
    ref PbfWriteStatus status)
    @safe
{
    StringTableBuilder table;
    table.initialize();

    foreach (ref const value; values)
    {
        prepareStrings(table, value.metadata, value.tags);
        foreach (ref const member; value.members)
            table.intern(member.role);
    }

    if (table.values.length > uint.max)
    {
        status.error = PbfWriteError.stringTableTooLarge;
        return false;
    }

    ubyte[] group;
    foreach (ref const value; values)
    {
        ubyte[] encoded;
        appendInt64Field(encoded, 1, value.id);
        appendTags(encoded, value.tags, table);

        const info = encodeInfo(value.metadata, table);
        if (info.length != 0)
            appendLengthDelimited(encoded, 4, info);

        ubyte[] roles;
        ubyte[] memberIds;
        ubyte[] memberTypes;
        long previousId;

        foreach (ref const member; value.members)
        {
            appendVarint(roles, table.intern(member.role));

            long delta;
            if (!checkedSub(member.id, previousId, delta))
            {
                status.error = PbfWriteError.integerOverflow;
                status.elementType = ElementType.relation;
                status.elementId = value.id;
                return false;
            }
            appendVarint(memberIds, encodeZigZag64(delta));
            previousId = member.id;

            final switch (member.type)
            {
                case ElementType.node:
                    appendVarint(memberTypes, 0);
                    break;
                case ElementType.way:
                    appendVarint(memberTypes, 1);
                    break;
                case ElementType.relation:
                    appendVarint(memberTypes, 2);
                    break;
            }
        }

        if (roles.length != 0)
        {
            appendLengthDelimited(encoded, 8, roles);
            appendLengthDelimited(encoded, 9, memberIds);
            appendLengthDelimited(encoded, 10, memberTypes);
        }

        appendLengthDelimited(group, 4, encoded);
    }

    payload = encodePrimitiveBlock(table, group);
    return true;
}

private ubyte[] encodePrimitiveBlock(
    ref StringTableBuilder table,
    scope const(ubyte)[] group)
    @safe
{
    ubyte[] stringTable;
    foreach (value; table.values)
        appendLengthDelimited(stringTable, 1, value);

    ubyte[] block;
    appendLengthDelimited(block, 1, stringTable);
    if (group.length != 0)
        appendLengthDelimited(block, 2, group);

    // Exact M4 semantic values are nanoseconds/milliseconds. Using granularity
    // one avoids any rounding or divisibility precondition.
    appendInt32Field(block, 17, 1);
    appendInt32Field(block, 18, 1);
    return block;
}

private void prepareStrings(
    ref StringTableBuilder table,
    ref const OwnedMetadata metadata,
    scope const(OwnedTag)[] tags)
    @safe
{
    if (metadata.hasUsername)
        table.intern(metadata.username);

    foreach (ref const tag; tags)
    {
        table.intern(tag.key);
        table.intern(tag.value);
    }
}

private void appendTags(
    ref ubyte[] encoded,
    scope const(OwnedTag)[] tags,
    ref StringTableBuilder table)
    @safe
{
    if (tags.length == 0)
        return;

    ubyte[] keys;
    ubyte[] values;

    foreach (ref const tag; tags)
    {
        appendVarint(keys, table.intern(tag.key));
        appendVarint(values, table.intern(tag.value));
    }

    appendLengthDelimited(encoded, 2, keys);
    appendLengthDelimited(encoded, 3, values);
}

private ubyte[] encodeInfo(
    ref const OwnedMetadata metadata,
    ref StringTableBuilder table)
    @safe
{
    ubyte[] result;

    if (metadata.hasVersion)
        appendInt32Field(result, 1, metadata.versionNumber);
    if (metadata.hasTimestamp)
        appendInt64Field(result, 2, metadata.timestampMilliseconds);
    if (metadata.hasChangeset)
        appendInt64Field(result, 3, metadata.changesetId);
    if (metadata.hasUserId)
        appendInt32Field(result, 4, metadata.userId);
    if (metadata.hasUsername)
        appendVarintField(result, 5, table.intern(metadata.username));
    if (metadata.hasVisibility)
        appendVarintField(result, 6, metadata.visible ? 1 : 0);

    return result;
}

private struct StringTableBuilder
{
    OwnedBytes[] values;
    uint[OwnedBytes] ids;

    void initialize() @safe
    {
        intern(OwnedBytes.init);
    }

    uint intern(OwnedBytes value) @safe
    {
        if (auto existing = value in ids)
            return *existing;

        assert(values.length <= uint.max);
        const id = cast(uint)values.length;
        values ~= value;
        ids[value] = id;
        return id;
    }
}

private bool appendFileBlock(
    ref ubyte[] target,
    string blockType,
    scope const(ubyte)[] payload,
    ref PbfWriteStatus status)
    @safe
{
    if (payload.length >= maxUncompressedBlobSize)
    {
        status.error = PbfWriteError.blockTooLarge;
        return false;
    }

    ubyte[] blob;
    appendLengthDelimited(blob, 1, payload);

    if (blob.length > maxSerializedBlobSize || blob.length > int.max)
    {
        status.error = PbfWriteError.blockTooLarge;
        return false;
    }

    ubyte[] typeBytes;
    typeBytes.length = blockType.length;
    foreach (i, char c; blockType)
        typeBytes[i] = cast(ubyte)c;

    ubyte[] header;
    appendLengthDelimited(header, 1, typeBytes);
    appendInt32Field(header, 3, cast(int)blob.length);

    if (header.length >= maxBlobHeaderSize ||
        header.length > uint.max)
    {
        status.error = PbfWriteError.blockTooLarge;
        return false;
    }

    appendBigEndianU32(target, cast(uint)header.length);
    target ~= header;
    target ~= blob;
    return true;
}

private size_t minSize(size_t a, size_t b)
    @safe pure nothrow @nogc
{
    return a < b ? a : b;
}

unittest
{
    import osm.io.pbf.document : PbfDocument;
    import osm.io.pbf.document_reader : readPbfDocument;
    import osm.io.pbf.reader : PbfReadStatus;
    import osm.model.owned :
        OwnedNode,
        OwnedRelation,
        OwnedRelationMember,
        OwnedTag,
        OwnedWay,
        OwnedWayNode;
    import osm.view.location : LocationView;

    PbfDocument source = PbfDocument.create();

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_000_000_001L, 16_000_000_002L);
    node.metadata.hasVersion = true;
    node.metadata.versionNumber = 7;
    node.metadata.hasTimestamp = true;
    node.metadata.timestampMilliseconds = 1_700_000_000_123L;
    node.metadata.hasUsername = true;
    node.metadata.username = ownBytes(cast(const(ubyte)[])"alice");
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"one"));
    source.data.nodes ~= node;

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedWayNode(
        1,
        true,
        LocationView(48_000_000_001L, 16_000_000_002L));
    way.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"highway"),
        ownBytes(cast(const(ubyte)[])"service"));
    source.data.ways ~= way;
    source.header.requiredFeatures ~= ownBytes(
        cast(const(ubyte)[])"LocationsOnWays");

    OwnedRelation relation;
    relation.id = 20;
    relation.members ~= OwnedRelationMember(
        ElementType.way,
        10,
        ownBytes(cast(const(ubyte)[])"outer"));
    source.data.relations ~= relation;

    PbfWriter writer;
    ubyte[] bytes;
    PbfWriteStatus writeStatus;
    assert(writer.write(source, bytes, writeStatus));
    assert(writeStatus.ok);
    assert(bytes.length != 0);

    PbfDocument decoded;
    PbfReadStatus readStatus;
    assert(readPbfDocument(bytes, decoded, readStatus));
    assert(readStatus.ok);

    assert(decoded.data.nodes.length == 1);
    assert(decoded.data.nodes[0].id == 1);
    assert(decoded.data.nodes[0].location.latitudeNanodegrees ==
        48_000_000_001L);
    assert(decoded.data.nodes[0].metadata.timestampMilliseconds ==
        1_700_000_000_123L);
    assert(decoded.data.nodes[0].tags[0].value ==
        cast(const(ubyte)[])"one");

    assert(decoded.data.ways.length == 1);
    assert(decoded.data.ways[0].nodes.length == 1);
    assert(decoded.data.ways[0].nodes[0].hasLocation);
    assert(decoded.data.ways[0].nodes[0].location.longitudeNanodegrees ==
        16_000_000_002L);

    assert(decoded.data.relations.length == 1);
    assert(decoded.data.relations[0].members[0].type == ElementType.way);
    assert(decoded.data.relations[0].members[0].role ==
        cast(const(ubyte)[])"outer");
}

unittest
{
    import osm.raw.pbf : PbfPreservationReason;

    PbfDocument document = PbfDocument.create();
    document.preservation.reason = PbfPreservationReason.unknownField;

    PbfWriter writer;
    ubyte[] output = [0xaa];
    PbfWriteStatus status;
    assert(!writer.write(document, output, status));
    assert(status.error == PbfWriteError.rewriteUnsafe);
    assert(output == [0xaa]);
}

unittest
{
    PbfDocument document = PbfDocument.create();
    document.preservation.source.bytes = cast(immutable(ubyte)[])[
        0x01, 0x02, 0x03
    ];

    PbfWriter writer;
    ubyte[] output;
    PbfWriteStatus status;
    assert(writer.writeOriginalSource(document, output, status));
    assert(output == [0x01, 0x02, 0x03]);
}


unittest
{
    import osm.model.owned : OwnedWay, OwnedWayNode;
    import osm.view.location : LocationView;

    // PbfDocument.create declares only OsmSchema-V0.6. Adding semantic
    // LocationsOnWays data without the matching required feature is an
    // inconsistent document; the writer must fail instead of repairing it.
    PbfDocument document = PbfDocument.create();

    OwnedWay way;
    way.id = 11;
    way.nodes ~= OwnedWayNode(1, true, LocationView(1, 2));
    document.data.ways ~= way;

    PbfWriter writer;
    ubyte[] output = [0xaa];
    PbfWriteStatus status;
    assert(!writer.write(document, output, status));
    assert(status.error == PbfWriteError.missingRequiredFeature);
    assert(output == [0xaa]);
}
