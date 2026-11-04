/**
 * Document-level metadata and semantic wrapper for OSM osmChange 0.6.
 *
 * The change payload itself is format-neutral and lives in
 * osm.model.change. This module contains only the XML document envelope.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.osmchange.document;

import osm.model.change : OwnedChangeSequence;
import osm.model.owned : OwnedBytes;

/** Root-level metadata observed on one osmChange document. */
struct OsmChangeDocumentInfo
{
    bool hasVersion;
    OwnedBytes versionText;

    bool hasGenerator;
    OwnedBytes generator;

    /** Create an independently mutable copy of aggregate storage. */
    OsmChangeDocumentInfo deepCopy() const @safe
    {
        OsmChangeDocumentInfo result;
        result.hasVersion = hasVersion;
        result.versionText = versionText;
        result.hasGenerator = hasGenerator;
        result.generator = generator;
        return result;
    }
}

/** Materialized semantic osmChange document. */
struct OsmChangeDocument
{
    OsmChangeDocumentInfo info;
    OwnedChangeSequence changes;

    /** Create an independently mutable change document. */
    OsmChangeDocument deepCopy() const @safe
    {
        OsmChangeDocument result;
        result.info = info.deepCopy();
        result.changes = changes.deepCopy();
        return result;
    }
}

unittest
{
    OsmChangeDocument document;
    document.info.hasVersion = true;
    document.info.versionText = cast(immutable(ubyte)[])"0.6";

    auto copy = document.deepCopy();
    assert(copy.info.versionText == document.info.versionText);
}
