/**
 * Consumer-facing PBF API.
 *
 * This facade contains PBF-specific reading, loss-aware document preservation,
 * writing, parallel summary decoding and PBF comparison helpers. Ordinary OSM
 * semantic values remain available from `import osm;`.
 */
module osm.pbf;

public import osm.io.pbf.reader :
    PbfNodeIterable,
    PbfWayIterable,
    PbfRelationIterable,
    PbfReadError,
    PbfReadStatus,
    PbfReadSummary,
    PbfReadResult,
    PbfReaderWorkspace,
    PbfReader,
    readPbf,
    pbfNodes,
    pbfWays,
    pbfRelations;

public import osm.io.pbf.parallel_reader :
    PbfParallelReadOptions,
    PbfParallelReader;

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

public import osm.model.compare :
    PbfSemanticField,
    PbfSemanticDifference,
    comparePbfSemantics,
    samePbfHeaderSemantics,
    samePbfSemantics,
    samePbfRawSource;
