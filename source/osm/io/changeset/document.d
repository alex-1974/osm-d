/**
 * OSM Changeset XML document envelope.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-06
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.changeset.document;

import osm.model.changeset : OwnedChangeset;
import osm.model.owned : OwnedBytes;

/** Root metadata observed on an OSM Changeset XML response. */
struct ChangesetDocumentInfo
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
}

/**
 * Materialized Changeset XML document.
 *
 * A read response ordinarily contains one Changeset. Query/list responses may
 * contain several and use the same semantic representation.
 */
struct ChangesetDocument
{
    ChangesetDocumentInfo info;
    OwnedChangeset[] changesets;

    /** Create an independently mutable document snapshot. */
    ChangesetDocument deepCopy() const @safe
    {
        ChangesetDocument result;
        result.info.hasVersion = info.hasVersion;
        result.info.versionText = info.versionText;
        result.info.hasGenerator = info.hasGenerator;
        result.info.generator = info.generator;
        result.info.hasCopyright = info.hasCopyright;
        result.info.copyrightText = info.copyrightText;
        result.info.hasAttribution = info.hasAttribution;
        result.info.attribution = info.attribution;
        result.info.hasLicense = info.hasLicense;
        result.info.license = info.license;
        result.changesets.length = changesets.length;
        foreach (i, ref const value; changesets)
            result.changesets[i] = value.deepCopy();
        return result;
    }
}

unittest
{
    ChangesetDocument document;
    document.changesets.length = 1;
    document.changesets[0].hasId = true;
    document.changesets[0].id = 7;

    auto copy = document.deepCopy();
    copy.changesets.length = 0;

    assert(document.changesets.length == 1);
    assert(document.changesets[0].id == 7);
}
