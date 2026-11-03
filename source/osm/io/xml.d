/**
 * Consumer-facing OSM XML API.
 *
 * This facade exposes the format-neutral semantic reader/writer boundary
 * without leaking dxml implementation types. Byte transport is provided by
 * transport-d through ByteSource and ByteSink parameters.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.xml;

public import osm.io.xml.document :
    OsmXmlBounds,
    OsmXmlDocumentInfo,
    OsmXmlDocument;

public import osm.io.xml.reader :
    OsmXmlReadError,
    OsmXmlReadStatus,
    OsmXmlReadOptions,
    OsmXmlReadSummary,
    OsmXmlReader,
    readOsmXmlDocument;

public import osm.io.xml.writer :
    OsmXmlWriteError,
    OsmXmlWriteStatus,
    OsmXmlWriteOptions,
    OsmXmlWriter;
