module app;

import osm;
import osm.capabilities;
import osm.validate;
import transport.source : MemorySource;

@safe void main()
{
    enum xml =
        "<osm version=\"0.6\" generator=\"OpenStreetMap server\">" ~
        "<api>" ~
        "<version minimum=\"0.6\" maximum=\"0.6\"/>" ~
        "<area maximum=\"0.25\"/>" ~
        "<waynodes maximum=\"1\"/>" ~
        "<relationmembers maximum=\"32000\"/>" ~
        "<changesets maximum_elements=\"10000\"/>" ~
        "<timeout seconds=\"300\"/>" ~
        "<status database=\"online\" api=\"online\" gpx=\"online\"/>" ~
        "</api>" ~
        "<policy><imagery><blacklist regex=\"example\"/></imagery></policy>" ~
        "</osm>";

    auto source = new MemorySource(cast(const(ubyte)[]) xml);

    EditingApiCapabilitiesDocument document;
    ApiCapabilitiesReadStatus readStatus;
    assert(readEditingApiCapabilities(
        source: source,
        document: document,
        status: readStatus));
    assert(readStatus.ok);

    CapabilityProfile profile = document.capabilities.validationProfile;
    assert(profile.maximumWayNodes == 1);
    assert(profile.maximumRelationMembers == 32_000);
    assert(profile.maximumChangesetElements == 10_000);
    assert(document.capabilities.apiState == ApiServiceState.online);

    OwnedWay way;
    way.id = -1;
    way.nodes ~= OwnedNodeRef(10);
    way.nodes ~= OwnedNodeRef(11);

    OwnedChangeSequence changes;
    changes.entries ~= OwnedChangeEntry.fromWay(ChangeAction.create, way);
    assert(changes.setChangeset(77));

    UploadValidationIssue issue;
    assert(!validateUploadChanges(changes, profile, issue));
    assert(issue.error == UploadValidationError.wayNodeLimitExceeded);
}
