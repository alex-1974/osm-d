/**
 * Consumer-facing osmChange 0.6 API.
 *
 * XML parser implementation types remain internal. Change payloads use the
 * format-independent osm.model.change types.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.osmchange;

public import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence;

public import osm.io.osmchange.document :
    OsmChangeDocumentInfo,
    OsmChangeDocument;

public import osm.io.osmchange.reader :
    OsmChangeReadError,
    OsmChangeReadStatus,
    OsmChangeReadOptions,
    OsmChangeReadSummary,
    OsmChangeReader,
    readOsmChangeDocument;

public import osm.io.osmchange.writer :
    OsmChangeWriteError,
    OsmChangeWriteStatus,
    OsmChangeWriteOptions,
    OsmChangeWriter;
