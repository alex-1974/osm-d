/**
 * Format-independent borrowed OpenStreetMap relation members.
 *
 * A relation member consists of the referenced OSM element kind and ID plus
 * the member role. Codec-specific lookup state such as PBF StringTable IDs does
 * not cross this semantic boundary.
 *
 * The role byte slice is borrowed from the source codec's backing storage and
 * must not outlive that backing data.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.relation_member;

import osm.view.element : ElementType, OsmId;

/**
 * One borrowed semantic OSM relation member.
 *
 * Member order and duplicate preservation are properties of the containing
 * relation-member range. This value does not resolve the referenced element.
 */
struct RelationMemberView
{
    /// OSM element kind of the referenced member.
    ElementType type;

    /// Signed OSM identifier of the referenced node, way, or relation.
    OsmId id;

    /**
     * Borrowed raw role bytes.
     *
     * Empty bytes represent the ordinary empty OSM relation-member role.
     * No UTF-8 repair or normalization is performed by this semantic view.
     */
    const(ubyte)[] role;
}

unittest
{
    const(ubyte)[] role = ['o', 'u', 't', 'e', 'r'];
    const member = RelationMemberView(ElementType.way, 42, role);

    assert(member.type == ElementType.way);
    assert(member.id == 42);
    assert(member.role == role);
}

unittest
{
    const member = RelationMemberView(ElementType.node, -7, null);

    assert(member.type == ElementType.node);
    assert(member.id == -7);
    assert(member.role.length == 0);
}
