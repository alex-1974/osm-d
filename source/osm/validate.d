/**
 * Consumer-facing OSM edit validation API.
 *
 * Validation is separate from parsing: codecs preserve representable source
 * semantics, while this module answers whether a change sequence satisfies the
 * current upload contract for a chosen target capability profile.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.validate;

public import osm.validation.capability :
    CapabilityProfile;

public import osm.validation.change :
    UploadValidationError,
    UploadValidationIssue,
    validateUploadChanges;

public import osm.validation.dataset :
    DatasetReferenceMode,
    DatasetReferenceError,
    DatasetReferenceIssue,
    DatasetReferenceSummary,
    validateDatasetReferences;
