module app;

import osm :
    ElementType,
    OwnedMetadata,
    OwnedNode,
    OwnedNodeRef,
    OwnedWay,
    OwnedDataset,
    OwnedChangeEntry,
    OwnedChangeSequence,
    ChangeAction,
    LocationView;
import osm.validate :
    CapabilityProfile,
    DatasetValidationMode,
    DatasetValidationError,
    DatasetValidationIssue,
    UploadValidationIssue,
    validateDataset,
    validateUploadChanges;

@safe void main()
{
    OwnedMetadata metadata;
    metadata.hasChangeset = true;
    metadata.changesetId = 42;

    OwnedNode node;
    node.id = -1;
    node.metadata = metadata;
    node.location = LocationView(48_200_000_000L, 16_300_000_000L);

    OwnedChangeSequence changes;
    changes.entries ~= OwnedChangeEntry.fromNode(ChangeAction.create, node);

    UploadValidationIssue issue;
    const ok = validateUploadChanges(
        changes,
        CapabilityProfile.unbounded(),
        issue);
    assert(ok);
    assert(issue.ok);

    OwnedDataset dataset;
    OwnedNode serverNode;
    serverNode.id = 1;
    dataset.nodes ~= serverNode;

    OwnedWay way;
    way.id = 2;
    way.nodes ~= OwnedNodeRef(1);
    dataset.ways ~= way;

    DatasetValidationIssue datasetIssue;
    assert(validateDataset(
        dataset,
        DatasetValidationMode.complete,
        datasetIssue));
    assert(datasetIssue.ok);

    dataset.ways[0].nodes[0].id = 999;
    assert(validateDataset(
        dataset,
        DatasetValidationMode.partial,
        datasetIssue));
    assert(!validateDataset(
        dataset,
        DatasetValidationMode.complete,
        datasetIssue));
    assert(datasetIssue.error == DatasetValidationError.missingReference);
}
