/**
 * OSM XML document-level metadata and durable semantic document wrapper.
 *
 * Element semantics remain in osm.model.owned. This module contains only
 * information carried by the OSM XML document envelope, such as root
 * attributes and bounds.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.xml.document;

import osm.model.owned : OwnedBytes, OwnedDataset;
import osm.view.location : LocationView;

/** One OSM XML bounds occurrence. */
struct OsmXmlBounds
{
    LocationView minimum;
    LocationView maximum;

    /// Whether the optional producer-specific origin attribute is present.
    bool hasOrigin;

    /// UTF-8 origin bytes when hasOrigin is true.
    OwnedBytes origin;
}

/**
 * Document-envelope metadata observed on an OSM XML input.
 *
 * Each root attribute has an independent presence bit because API responses,
 * extracts, editor files, and hand-written fixtures do not all carry the same
 * metadata. Unknown root attributes are not stored here; the semantic reader
 * fails explicitly on unsupported attributes instead of discarding them.
 */
struct OsmXmlDocumentInfo
{
    bool hasVersion;
    OwnedBytes version;

    bool hasGenerator;
    OwnedBytes generator;

    bool hasCopyright;
    OwnedBytes copyrightText;

    bool hasAttribution;
    OwnedBytes attribution;

    bool hasLicense;
    OwnedBytes license;

    /// Bounds occurrences in source order.
    OsmXmlBounds[] bounds;

    /** Create an independently mutable copy of aggregate storage. */
    OsmXmlDocumentInfo deepCopy() const @safe
    {
        OsmXmlDocumentInfo result = this;
        result.bounds = bounds.dup;
        return result;
    }
}

/**
 * Materialized OSM XML semantic document.
 *
 * Streaming consumers do not need this type. It is a convenience boundary for
 * callers that deliberately want to retain the complete dataset.
 */
struct OsmXmlDocument
{
    OsmXmlDocumentInfo info;
    OwnedDataset data;

    /** Create an independently mutable copy of aggregate storage. */
    OsmXmlDocument deepCopy() const @safe
    {
        OsmXmlDocument result;
        result.info = info.deepCopy();
        result.data = data.deepCopy();
        return result;
    }
}

unittest
{
    OsmXmlDocument document;
    document.info.hasVersion = true;
    document.info.version = cast(immutable(ubyte)[])"0.6";
    document.info.bounds ~= OsmXmlBounds(
        LocationView(48_000_000_000L, 16_000_000_000L),
        LocationView(49_000_000_000L, 17_000_000_000L));

    auto copy = document.deepCopy();
    copy.info.bounds.length = 0;

    assert(document.info.bounds.length == 1);
}
