/**
 * Consumer-facing OSM Editing API capability discovery.
 *
 * This facade parses the XML capabilities response into the editing/upload
 * policy needed by osm-d validation. HTTP, endpoint selection, authentication
 * and retry behavior remain outside osm-d.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.capabilities;

public import osm.validation.capability :
    CapabilityProfile;

public import osm.io.capabilities.document :
    ApiServiceState,
    ApiCapabilitiesDocumentInfo,
    EditingApiCapabilities,
    EditingApiCapabilitiesDocument;

public import osm.io.capabilities.reader :
    ApiCapabilitiesReadError,
    ApiCapabilitiesReadStatus,
    ApiCapabilitiesReadOptions,
    ApiCapabilitiesReader,
    readEditingApiCapabilities;
