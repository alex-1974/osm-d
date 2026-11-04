/**
 * Consumer-facing OSM diff-upload response API.
 *
 * This facade parses the XML diffResult returned by the OSM Editing API into
 * the format-neutral UploadResult model. HTTP transport, authentication and
 * changeset lifecycle remain outside osm-d.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.upload;

public import osm.model.change :
    UploadResultEffect,
    UploadResultEntry,
    UploadResult;

public import osm.io.upload.document :
    UploadResultDocumentInfo,
    UploadResultDocument;

public import osm.io.upload.reader :
    UploadResultReadError,
    UploadResultReadStatus,
    UploadResultReadOptions,
    UploadResultReadSummary,
    UploadResultReader,
    readUploadResult,
    readUploadResultDocument;
