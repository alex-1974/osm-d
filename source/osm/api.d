/**
 * Consumer-facing OpenStreetMap Editing API 0.6 client.
 *
 * Import this module when an application wants OSM protocol operations over an
 * injected transport-d HttpExchange. Generic HTTP execution remains outside
 * osm-d; credentials are supplied only at individual request boundaries.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.api;

public import osm.api.client :
    EditingApiClient,
    EditingApiFailure,
    EditingApiResponseKind,
    EditingApiServer,
    EditingApiServerError,
    EditingApiStatus;

public import osm.api.permissions :
    EditingApiPermissions;

public import osm.io.capabilities.document :
    ApiServiceState,
    EditingApiCapabilities,
    EditingApiCapabilitiesDocument;

public import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence,
    UploadResult,
    UploadResultEntry,
    UploadResultEffect;

public import osm.model.changeset :
    ChangesetId,
    ChangesetBounds,
    ChangesetTagRequest,
    OwnedChangeset,
    OwnedChangesetComment;

public import osm.model.owned :
    OwnedDataset,
    OwnedNode,
    OwnedNodeRef,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    ownBytes;

public import osm.view.element :
    ElementType,
    OsmId;

public import osm.view.location :
    LocationView;
