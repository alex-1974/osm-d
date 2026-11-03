module osm.tests.pbf_roundtrip;

import osm;

import std.file : read, write;
import std.stdio : stderr, writeln;

private immutable(ubyte)[] bytes(string value)
{
    return ownBytes(cast(const(ubyte)[])value);
}

private PbfDocument makeEdgeDocument()
{
    PbfDocument document = PbfDocument.create();

    document.header.hasBBox = true;
    document.header.bbox = PbfHeaderBBox(
        -1_000_000_001L,
        2_000_000_002L,
        3_000_000_003L,
        -4_000_000_004L);
    document.header.requiredFeatures ~= bytes("LocationsOnWays");
    document.header.requiredFeatures ~= bytes("HistoricalInformation");
    document.header.optionalFeatures ~= bytes("Has_Metadata");
    document.header.hasWritingProgram = true;
    document.header.writingProgram = bytes("osm-d-roundtrip-self-test");
    document.header.hasSource = true;
    document.header.source = bytes("synthetic-edge-corpus");
    document.header.hasReplicationTimestamp = true;
    document.header.replicationTimestamp = 1_700_000_000L;
    document.header.hasReplicationSequenceNumber = true;
    document.header.replicationSequenceNumber = 42;
    document.header.hasReplicationBaseUrl = true;
    document.header.replicationBaseUrl = bytes("https://example.invalid/replication");

    OwnedNode node;
    node.id = 101;
    node.location = LocationView(
        48_208_174_301L,
        16_373_818_909L);
    node.metadata.hasVersion = true;
    node.metadata.versionNumber = 3;
    node.metadata.hasTimestamp = true;
    node.metadata.timestampMilliseconds = 1_700_000_000_123L;
    node.metadata.hasChangeset = true;
    node.metadata.changesetId = 991;
    node.metadata.hasUserId = true;
    node.metadata.userId = 77;
    node.metadata.hasUsername = true;
    node.metadata.username = bytes("alice");
    node.metadata.hasVisibility = true;
    node.metadata.visible = true;
    node.tags ~= OwnedTag(bytes("name"), bytes("A"));
    node.tags ~= OwnedTag(bytes("name"), bytes("A"));
    document.data.nodes ~= node;

    OwnedNode node2;
    node2.id = 102;
    node2.location = LocationView(
        -12_345_678_901L,
        179_999_999_999L);
    document.data.nodes ~= node2;

    OwnedWay way;
    way.id = 201;
    way.metadata.hasVisibility = true;
    way.metadata.visible = false;
    way.tags ~= OwnedTag(bytes("highway"), bytes("service"));
    way.nodes ~= OwnedWayNode(
        101,
        true,
        LocationView(48_208_174_301L, 16_373_818_909L));
    way.nodes ~= OwnedWayNode(
        101,
        true,
        LocationView(48_208_174_301L, 16_373_818_909L));
    way.nodes ~= OwnedWayNode(
        102,
        true,
        LocationView(-12_345_678_901L, 179_999_999_999L));
    document.data.ways ~= way;

    OwnedRelation relation;
    relation.id = 301;
    relation.metadata.hasVersion = true;
    relation.metadata.versionNumber = 1;
    relation.tags ~= OwnedTag(bytes("type"), bytes("multipolygon"));
    relation.members ~= OwnedRelationMember(
        ElementType.way, 201, bytes("outer"));
    relation.members ~= OwnedRelationMember(
        ElementType.node, 101, bytes("label"));
    relation.members ~= OwnedRelationMember(
        ElementType.way, 201, bytes("outer"));
    document.data.relations ~= relation;

    return document;
}

private bool roundTrip(
    ref const PbfDocument source,
    out ubyte[] encoded,
    out PbfDocument decoded)
{
    PbfWriter writer;
    PbfWriteStatus writeStatus;
    if (!writer.write(source, encoded, writeStatus))
    {
        stderr.writeln("semantic write failed: ", writeStatus.error);
        return false;
    }

    PbfReadStatus readStatus;
    if (!readPbfDocument(encoded, decoded, readStatus))
    {
        stderr.writeln("round-trip read failed: ", readStatus.error);
        return false;
    }

    PbfSemanticDifference difference;
    if (!comparePbfSemantics(source, decoded, difference))
    {
        stderr.write(
            "semantic comparator mismatch: field=",
            difference.field);
        if (difference.hasElement)
        {
            stderr.write(
                " element=", difference.elementType,
                "/", difference.elementId,
                " element_index=", difference.elementIndex);
        }
        if (difference.hasChild)
            stderr.write(" child_index=", difference.childIndex);
        stderr.writeln();
        return false;
    }

    return true;
}

private int selfTest()
{
    auto source = makeEdgeDocument();

    ubyte[] encoded;
    PbfDocument decoded;
    if (!roundTrip(source, encoded, decoded))
        return 1;

    // The reader captured the newly generated file exactly.
    PbfWriter writer;
    PbfWriteStatus originalStatus;
    ubyte[] reproduced;
    if (!writer.writeOriginalSource(
            decoded,
            reproduced,
            originalStatus))
    {
        stderr.writeln("exact-source reproduction failed");
        return 1;
    }

    if (reproduced != encoded)
    {
        stderr.writeln("exact-source reproduction mismatch");
        return 1;
    }

    // Prove that ordinary semantic edits survive another rewrite.
    decoded.data.nodes[0].tags[0].value = bytes("Edited");
    ubyte[] editedBytes;
    PbfDocument editedDecoded;
    if (!roundTrip(decoded, editedBytes, editedDecoded))
        return 1;

    writeln(
        "roundtrip self-test: PASS nodes=",
        editedDecoded.data.nodes.length,
        " ways=", editedDecoded.data.ways.length,
        " relations=", editedDecoded.data.relations.length);
    return 0;
}

private int qualifyFile(string inputPath, string outputPath)
{
    auto inputStorage = cast(ubyte[])read(inputPath);
    const(ubyte)[] input = inputStorage;

    PbfDocument source;
    PbfReadStatus readStatus;
    if (!readPbfDocument(input, source, readStatus))
    {
        stderr.writeln(
            "input decode failed: ", readStatus.error,
            " block=", readStatus.blockSequence,
            " offset=", readStatus.blockOffset);
        return 1;
    }

    if (!source.preservation.semanticRewriteSafe)
    {
        stderr.writeln(
            "input is readable but semantic rewrite is unsafe: ",
            source.preservation.reason,
            " block_offset=",
            source.preservation.firstSensitiveOffset);
        return 3;
    }

    PbfWriter writer;
    PbfWriteStatus writeStatus;
    ubyte[] encoded;
    if (!writer.write(source, encoded, writeStatus))
    {
        stderr.writeln(
            "semantic write failed: ", writeStatus.error,
            " element=", writeStatus.elementType,
            "/", writeStatus.elementId);
        return 1;
    }

    PbfDocument decoded;
    PbfReadStatus rewrittenStatus;
    if (!readPbfDocument(encoded, decoded, rewrittenStatus))
    {
        stderr.writeln(
            "rewritten file decode failed: ", rewrittenStatus.error);
        return 1;
    }

    PbfSemanticDifference difference;
    if (!comparePbfSemantics(source, decoded, difference))
    {
        stderr.write(
            "semantic round-trip mismatch: field=",
            difference.field);
        if (difference.hasElement)
        {
            stderr.write(
                " element=", difference.elementType,
                "/", difference.elementId,
                " element_index=", difference.elementIndex);
        }
        if (difference.hasChild)
            stderr.write(" child_index=", difference.childIndex);
        stderr.writeln();
        return 1;
    }

    write(outputPath, encoded);

    writeln(
        "semantic_roundtrip=PASS",
        " input_bytes=", input.length,
        " output_bytes=", encoded.length,
        " nodes=", source.data.nodes.length,
        " ways=", source.data.ways.length,
        " relations=", source.data.relations.length);
    return 0;
}

private void usage(string program)
{
    stderr.writeln(
        "usage: ", program,
        " --self-test | <input.osm.pbf> <output.osm.pbf>");
}

int main(string[] args)
{
    if (args.length == 2 && args[1] == "--self-test")
        return selfTest();

    if (args.length == 3)
        return qualifyFile(args[1], args[2]);

    usage(args[0]);
    return 2;
}
