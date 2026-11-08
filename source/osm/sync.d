/**
 * Consumer-facing OSM history, refresh and conflict semantics.
 *
 * This facade is transport-independent. Applications may obtain remote values
 * through osm.api, fixtures, replication, or another trusted source and then
 * reconcile them with an editable OsmStore.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.sync;

public import osm.history :
    ElementHistory,
    HistoricalVisibility,
    HistoryCoverage,
    HistoryError,
    HistoryStatus,
    NodeHistory,
    RelationHistory,
    WayHistory;

public import osm.model.conflict :
    ConflictDisposition,
    ConflictReport,
    ElementState,
    FieldChange,
    NodeState,
    RelationState,
    SequenceChange,
    SequenceEditSpan,
    TagChange,
    TagConflict,
    WayState,
    classifyConflict;

public import osm.reconcile.authoritative :
    AuthoritativeBatch,
    ReconcileAction,
    ReconcileEntry,
    ReconcileError,
    ReconcileResult,
    ReconcileStatus,
    reconcileAuthoritative;
