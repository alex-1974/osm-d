module app;

import osm :
    ElementType,
    OwnedMetadata,
    OwnedNode,
    OwnedChangeEntry,
    OwnedChangeSequence,
    ChangeAction,
    LocationView;
import osm.validate :
    CapabilityProfile,
    UploadValidationIssue,
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
}
