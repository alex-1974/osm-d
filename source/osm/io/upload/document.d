/**
 * Durable document-envelope metadata for OSM API diffResult responses.
 *
 * The result entries themselves remain in osm.model.change.UploadResult.
 * This module models only XML response-envelope metadata.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.upload.document;

import osm.model.change : UploadResult;
import osm.model.owned : OwnedBytes;

/**
 * Root metadata observed on one OSM API diffResult response.
 *
 * Current OpenStreetMap server responses inherit the ordinary API XML root
 * attributes even though the root element is renamed to diffResult.
 * Presence bits remain explicit because fixtures/proxies/compatible servers
 * need not emit every optional informational attribute.
 */
struct UploadResultDocumentInfo
{
    bool hasVersion;
    OwnedBytes versionText;

    bool hasGenerator;
    OwnedBytes generator;

    bool hasCopyright;
    OwnedBytes copyrightText;

    bool hasAttribution;
    OwnedBytes attribution;

    bool hasLicense;
    OwnedBytes license;

    /**
     * Create an independently mutable metadata value.
     *
     * Returns:
     *   A value copy. Immutable byte strings may safely remain shared.
     */
    UploadResultDocumentInfo deepCopy() const @safe
    {
        return this;
    }
}

/** Materialized OSM API diffResult response. */
struct UploadResultDocument
{
    UploadResultDocumentInfo info;
    UploadResult result;

    /**
     * Create an independently mutable document.
     *
     * Returns:
     *   A copy with an independently mutable result-entry array.
     */
    UploadResultDocument deepCopy() const @safe
    {
        UploadResultDocument copy;
        copy.info = info.deepCopy();
        copy.result.entries = result.entries.dup;
        return copy;
    }
}

unittest
{
    UploadResultDocument document;
    document.info.hasVersion = true;
    document.info.versionText = cast(immutable(ubyte)[])"0.6";
    document.result.entries.length = 1;

    auto copy = document.deepCopy();
    copy.result.entries.length = 0;

    assert(document.result.entries.length == 1);
}
