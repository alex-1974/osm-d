/**
 * Public package root for `osm-d`.
 *
 * `osm-d` provides loss-aware, high-performance OpenStreetMap data handling.
 * The public surface is intentionally kept small while the canonical data
 * model, codecs, validation rules, and streaming contracts are established.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-09-12
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm;

public import osm.view.element :
    ElementType,
    OsmId;
public import osm.model.compare :
    PbfSemanticField,
    PbfSemanticDifference,
    comparePbfSemantics,
    sameOsmSemantics,
    samePbfHeaderSemantics,
    samePbfSemantics,
    samePbfRawSource;
public import osm.model.owned :
    OwnedBytes,
    OwnedTag,
    OwnedMetadata,
    OwnedWayNode,
    OwnedRelationMember,
    OwnedNode,
    OwnedWay,
    OwnedRelation,
    OwnedDataset,
    ownBytes;
public import osm.model.change :
    ChangeAction,
    ChangeObjectState,
    OwnedChangeEntry,
    OwnedChangeSequence;
public import osm.raw.pbf :
    PbfPreservationReason,
    PbfRawFile,
    PbfPreservation;
public import osm.io.pbf.document :
    PbfHeaderBBox,
    PbfHeader,
    PbfDocument;
public import osm.io.pbf.document_reader : readPbfDocument;
public import osm.io.pbf.writer :
    PbfWriteError,
    PbfWriteStatus,
    PbfWriteOptions,
    PbfWriter;
public import osm.view.location : LocationView;
public import osm.view.metadata : MetadataView;
public import osm.io.pbf.node_view : NodeView;
public import osm.io.pbf.way : WayView;
public import osm.io.pbf.relation : RelationView;
public import osm.view.relation_member : RelationMemberView;
public import osm.view.tag : TagView;
public import osm.view.way_node : WayNodeView;

public import osm.io.pbf.reader :
    PbfNodeIterable,
    PbfWayIterable,
    PbfRelationIterable,
    PbfReadError,
    PbfReadStatus,
    PbfReadSummary,
    PbfReaderWorkspace,
    PbfReader;
public import osm.io.pbf.parallel_reader :
    PbfParallelReadOptions,
    PbfParallelReader;
