/**
 * Consumer-facing OSM Changeset semantic and XML API.
 *
 * This focused facade models server Changesets and the tag-only XML request
 * used by Changeset create/update operations. It performs no HTTP and makes no
 * editor-policy decision about when a Changeset should be opened or closed.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-06
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.changeset;

public import osm.model.changeset :
    ChangesetId,
    ChangesetBounds,
    OwnedChangesetComment,
    OwnedChangeset,
    ChangesetTagRequest;

public import osm.io.changeset.document :
    ChangesetDocumentInfo,
    ChangesetDocument;

public import osm.io.changeset.reader :
    ChangesetReadError,
    ChangesetReadStatus,
    ChangesetReadOptions,
    ChangesetReadSummary,
    ChangesetReader,
    readChangeset,
    readChangesetDocument;

public import osm.io.changeset.writer :
    ChangesetWriteError,
    ChangesetWriteStatus,
    ChangesetWriteOptions,
    ChangesetWriter,
    writeChangesetTagRequest;
