/**
 * OSMPBF HeaderBlock feature classification and required-feature policy.
 *
 * Structural HeaderBlock decoding is intentionally separate from deciding
 * whether a particular reader configuration understands all required file
 * features. This module performs that capability check without allocating and
 * reports the first unsupported required feature by borrowed byte slice.
 *
 * Unknown optional features never block read-only semantic interpretation.
 * Their presence is still reported because a future semantic rewrite must not
 * silently erase or reinterpret them.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.pbf.features;

import osm.io.pbf.error : PbfError, PbfStatus;
import osm.io.pbf.header_block :
    HeaderBlockView,
    HeaderFeatureRef;

/** Semantic classification of currently documented HeaderBlock features. */
enum HeaderFeatureKind : ubyte
{
    /// Feature string is not currently understood by osm-d.
    unknown,
    /// OSM data uses schema version 0.6.
    osmSchemaV06,
    /// PrimitiveBlocks may use DenseNodes/DenseInfo encoding.
    denseNodes,
    /// File carries history/deletion visibility semantics.
    historicalInformation,
    /// Ways may carry parallel delta-coded latitude/longitude columns.
    locationsOnWays,
    /// Optional declaration that author/timestamp metadata is present.
    hasMetadata,
    /// Optional type-then-ID sorting declaration.
    sortTypeThenId,
    /// Optional geographic sorting declaration.
    sortGeographic,
    /// Legacy optional `timestamp=...` feature declaration.
    legacyTimestamp,
}

/**
 * Reader capabilities that can change how OSM entity bytes are interpreted.
 *
 * A later full-file reader supplies this policy only for features whose data
 * semantics it actually implements. Descriptive optional features such as sort
 * declarations are understood independently and require no capability bit.
 */
struct HeaderFeatureSupport
{
    /// Reader implements the OSM 0.6 semantic schema represented by the file.
    bool osmSchemaV06;
    /// Reader implements DenseNodes and DenseInfo semantics.
    bool denseNodes;
    /// Reader implements HistoricalInformation visibility/history semantics.
    bool historicalInformation;
    /// Reader implements LocationsOnWays way-coordinate columns.
    bool locationsOnWays;

    /** Return a policy enabling every currently semantic feature kind. */
    static HeaderFeatureSupport allKnown() @safe pure nothrow @nogc
    {
        return HeaderFeatureSupport(true, true, true, true);
    }
}

/** Summary of feature declarations and compatibility with one reader policy. */
struct HeaderFeatureAssessment
{
    /// Number of correctly encoded required feature occurrences.
    size_t requiredCount;
    /// Number of correctly encoded optional feature occurrences.
    size_t optionalCount;
    /// Number of required occurrences unsupported by the supplied policy.
    size_t unsupportedRequiredCount;
    /// Number of optional occurrences not currently recognized by osm-d.
    size_t unknownOptionalCount;
    /// First unsupported required occurrence, if any.
    HeaderFeatureRef firstUnsupportedRequired;
    /// Header declares `OsmSchema-V0.6` in either feature list.
    bool hasOsmSchemaV06;
    /// Header declares `DenseNodes` in either feature list.
    bool hasDenseNodes;
    /// Header declares `HistoricalInformation` in either feature list.
    bool hasHistoricalInformation;
    /// Header declares `LocationsOnWays` in either feature list.
    bool hasLocationsOnWays;

    /** Returns whether all required feature occurrences are supported. */
    @property bool readable() const @safe pure nothrow @nogc
    {
        return unsupportedRequiredCount == 0;
    }

    /** Returns whether unknown optional declarations require preservation care. */
    @property bool hasUnknownOptional() const @safe pure nothrow @nogc
    {
        return unknownOptionalCount != 0;
    }
}

/**
 * Classify one raw HeaderBlock feature string.
 *
 * Params:
 *   feature = Raw protobuf string bytes.
 *
 * Returns:
 *   The documented feature kind, or `HeaderFeatureKind.unknown`.
 */
HeaderFeatureKind classifyHeaderFeature(const(ubyte)[] feature)
    @safe pure nothrow @nogc
{
    if (equalsAscii(feature, "OsmSchema-V0.6"))
        return HeaderFeatureKind.osmSchemaV06;
    if (equalsAscii(feature, "DenseNodes"))
        return HeaderFeatureKind.denseNodes;
    if (equalsAscii(feature, "HistoricalInformation"))
        return HeaderFeatureKind.historicalInformation;
    if (equalsAscii(feature, "LocationsOnWays"))
        return HeaderFeatureKind.locationsOnWays;
    if (equalsAscii(feature, "Has_Metadata"))
        return HeaderFeatureKind.hasMetadata;
    if (equalsAscii(feature, "Sort.Type_then_ID"))
        return HeaderFeatureKind.sortTypeThenId;
    if (equalsAscii(feature, "Sort.Geographic"))
        return HeaderFeatureKind.sortGeographic;
    if (startsWithAscii(feature, "timestamp="))
        return HeaderFeatureKind.legacyTimestamp;
    return HeaderFeatureKind.unknown;
}

/**
 * Assess HeaderBlock feature declarations against an explicit reader policy.
 *
 * Required declarations are checked in wire order. Unknown required features
 * and known semantic features disabled in `support` are both unsupported.
 * Unknown optional features are counted but never make `readable` false.
 *
 * Params:
 *   header = Structurally decoded HeaderBlock.
 *   support = Semantic capabilities of the intended reader path.
 *
 * Returns:
 *   Allocation-free compatibility summary borrowing any reported feature bytes
 *   from `header.raw`.
 */
HeaderFeatureAssessment assessHeaderFeatures(
    ref const HeaderBlockView header,
    HeaderFeatureSupport support)
    @safe nothrow @nogc
{
    HeaderFeatureAssessment result;

    auto required = header.requiredFeatures;
    while (!required.empty)
    {
        const feature = required.front;
        ++result.requiredCount;
        const kind = classifyHeaderFeature(feature.bytes);
        noteFeature(result, kind);

        if (!supportsRequired(kind, support))
        {
            ++result.unsupportedRequiredCount;
            if (result.unsupportedRequiredCount == 1)
                result.firstUnsupportedRequired = feature;
        }
        required.popFront();
    }

    auto optional = header.optionalFeatures;
    while (!optional.empty)
    {
        const feature = optional.front;
        ++result.optionalCount;
        const kind = classifyHeaderFeature(feature.bytes);
        noteFeature(result, kind);
        if (kind == HeaderFeatureKind.unknown)
            ++result.unknownOptionalCount;
        optional.popFront();
    }

    return result;
}

/**
 * Validate that every required feature is understood by one reader policy.
 *
 * Params:
 *   header = Structurally decoded HeaderBlock.
 *   support = Semantic capabilities of the intended reader path.
 *   assessment = Receives the complete feature assessment.
 *   status = Receives `unsupportedRequiredFeature` at the first offending
 *            field occurrence, or success.
 *
 * Returns:
 *   `true` when all required features are supported; `false` otherwise.
 */
bool validateRequiredFeatures(
    ref const HeaderBlockView header,
    HeaderFeatureSupport support,
    out HeaderFeatureAssessment assessment,
    out PbfStatus status)
    @safe nothrow @nogc
{
    assessment = assessHeaderFeatures(header, support);
    if (!assessment.readable)
    {
        status = PbfStatus.failure(
            PbfError.unsupportedRequiredFeature,
            assessment.firstUnsupportedRequired.offset,
            4);
        return false;
    }

    status = PbfStatus.init;
    return true;
}

private bool supportsRequired(
    HeaderFeatureKind kind,
    HeaderFeatureSupport support)
    @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case HeaderFeatureKind.unknown:
            return false;
        case HeaderFeatureKind.osmSchemaV06:
            return support.osmSchemaV06;
        case HeaderFeatureKind.denseNodes:
            return support.denseNodes;
        case HeaderFeatureKind.historicalInformation:
            return support.historicalInformation;
        case HeaderFeatureKind.locationsOnWays:
            return support.locationsOnWays;
        case HeaderFeatureKind.hasMetadata:
        case HeaderFeatureKind.sortTypeThenId:
        case HeaderFeatureKind.sortGeographic:
        case HeaderFeatureKind.legacyTimestamp:
            return true;
    }
}

private void noteFeature(
    ref HeaderFeatureAssessment result,
    HeaderFeatureKind kind)
    @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case HeaderFeatureKind.osmSchemaV06:
            result.hasOsmSchemaV06 = true;
            break;
        case HeaderFeatureKind.denseNodes:
            result.hasDenseNodes = true;
            break;
        case HeaderFeatureKind.historicalInformation:
            result.hasHistoricalInformation = true;
            break;
        case HeaderFeatureKind.locationsOnWays:
            result.hasLocationsOnWays = true;
            break;
        case HeaderFeatureKind.unknown:
        case HeaderFeatureKind.hasMetadata:
        case HeaderFeatureKind.sortTypeThenId:
        case HeaderFeatureKind.sortGeographic:
        case HeaderFeatureKind.legacyTimestamp:
            break;
    }
}

private bool equalsAscii(const(ubyte)[] bytes, string ascii)
    @safe pure nothrow @nogc
{
    if (bytes.length != ascii.length)
        return false;

    foreach (i; 0 .. bytes.length)
    {
        if (bytes[i] != cast(ubyte)ascii[i])
            return false;
    }
    return true;
}

private bool startsWithAscii(const(ubyte)[] bytes, string ascii)
    @safe pure nothrow @nogc
{
    if (bytes.length < ascii.length)
        return false;

    foreach (i; 0 .. ascii.length)
    {
        if (bytes[i] != cast(ubyte)ascii[i])
            return false;
    }
    return true;
}

unittest
{
    import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;

    // required OsmSchema-V0.6, DenseNodes, FutureFeature
    // optional LocationsOnWays, FutureOptional
    const(ubyte)[] bytes = [
        0x22, 0x0e,
            0x4f, 0x73, 0x6d, 0x53, 0x63, 0x68, 0x65,
            0x6d, 0x61, 0x2d, 0x56, 0x30, 0x2e, 0x36,
        0x22, 0x0a,
            0x44, 0x65, 0x6e, 0x73, 0x65, 0x4e, 0x6f, 0x64, 0x65, 0x73,
        0x22, 0x0d,
            0x46, 0x75, 0x74, 0x75, 0x72, 0x65, 0x46, 0x65, 0x61, 0x74, 0x75, 0x72, 0x65,
        0x2a, 0x0f,
            0x4c, 0x6f, 0x63, 0x61, 0x74, 0x69, 0x6f, 0x6e,
            0x73, 0x4f, 0x6e, 0x57, 0x61, 0x79, 0x73,
        0x2a, 0x0e,
            0x46, 0x75, 0x74, 0x75, 0x72, 0x65, 0x4f, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x61, 0x6c,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(bytes, header, status));

    HeaderFeatureSupport support;
    support.osmSchemaV06 = true;
    support.denseNodes = true;

    HeaderFeatureAssessment assessment;
    assert(!validateRequiredFeatures(header, support, assessment, status));
    assert(status.error == PbfError.unsupportedRequiredFeature);
    assert(status.fieldNumber == 4);
    assert(assessment.requiredCount == 3);
    assert(assessment.unsupportedRequiredCount == 1);
    assert(assessment.optionalCount == 2);
    assert(assessment.unknownOptionalCount == 1);
    assert(assessment.hasOsmSchemaV06);
    assert(assessment.hasDenseNodes);
    assert(assessment.hasLocationsOnWays);
    assert(assessment.firstUnsupportedRequired.bytes.length == 13);
}

unittest
{
    import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;

    const(ubyte)[] bytes = [
        0x22, 0x0e,
            0x4f, 0x73, 0x6d, 0x53, 0x63, 0x68, 0x65,
            0x6d, 0x61, 0x2d, 0x56, 0x30, 0x2e, 0x36,
        0x22, 0x15,
            0x48, 0x69, 0x73, 0x74, 0x6f, 0x72, 0x69, 0x63, 0x61, 0x6c,
            0x49, 0x6e, 0x66, 0x6f, 0x72, 0x6d, 0x61, 0x74, 0x69, 0x6f, 0x6e,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(bytes, header, status));

    auto support = HeaderFeatureSupport.allKnown();
    HeaderFeatureAssessment assessment;
    assert(validateRequiredFeatures(header, support, assessment, status));
    assert(status.ok && assessment.readable);
    assert(assessment.hasHistoricalInformation);
}

unittest
{
    import osm.io.pbf.header_block : HeaderBlockView, decodeHeaderBlock;

    // A known but disabled semantic feature is rejected when required, while
    // an unknown optional declaration alone does not block reading.
    const(ubyte)[] requiredDense = [
        0x22, 0x0a,
            0x44, 0x65, 0x6e, 0x73, 0x65, 0x4e, 0x6f, 0x64, 0x65, 0x73,
        0x2a, 0x0e,
            0x46, 0x75, 0x74, 0x75, 0x72, 0x65, 0x4f, 0x70, 0x74, 0x69, 0x6f, 0x6e, 0x61, 0x6c,
    ];

    HeaderBlockView header;
    PbfStatus status;
    assert(decodeHeaderBlock(requiredDense, header, status));

    HeaderFeatureSupport support;
    HeaderFeatureAssessment assessment;
    assert(!validateRequiredFeatures(header, support, assessment, status));
    assert(assessment.unsupportedRequiredCount == 1);
    assert(assessment.unknownOptionalCount == 1);

    support.denseNodes = true;
    assert(validateRequiredFeatures(header, support, assessment, status));
    assert(assessment.readable);
    assert(assessment.unknownOptionalCount == 1);
    assert(assessment.hasUnknownOptional);
}
