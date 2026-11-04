/**
 * Target-server capability limits used by OSM upload validation.
 *
 * API capability values are server/policy state rather than format constants.
 * A zero field means that no target-server limit is enforced for that category.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.validation.capability;

/** Optional target-server limits for edit/upload validation. */
struct CapabilityProfile
{
    /// Maximum objects in one changeset/upload scope; zero means unspecified.
    size_t maximumChangesetElements;

    /// Maximum node references in one Way; zero means unspecified.
    size_t maximumWayNodes;

    /// Maximum members in one Relation; zero means unspecified.
    size_t maximumRelationMembers;

    /** No target-server-specific limits. */
    static CapabilityProfile unbounded()
        @safe pure nothrow @nogc
    {
        return CapabilityProfile.init;
    }
}

unittest
{
    auto profile = CapabilityProfile.unbounded();
    assert(profile.maximumChangesetElements == 0);
}
