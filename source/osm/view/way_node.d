/**
 * Format-independent semantic OpenStreetMap Way node references.
 *
 * A Way node reference always carries the referenced OSM node ID. Some input
 * formats may additionally carry an exact node location alongside that
 * reference. The semantic view keeps that optionality explicit without
 * exposing codec-specific parallel columns.
 *
 * This value performs no node lookup and owns no external resource.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.way_node;

import osm.view.element : OsmId;
import osm.view.location : LocationView;

/**
 * One ordered node reference contained by an OSM Way.
 *
 * The referenced node is not resolved. `location` is available only when the
 * source representation carried a location aligned with this reference.
 */
struct WayNodeView
{
    /// Signed OSM identifier of the referenced node.
    OsmId id;

private:
    bool _hasLocation;
    LocationView _location;

package(osm):
    this(OsmId id) @safe pure nothrow @nogc
    {
        this.id = id;
    }

    this(OsmId id, LocationView location) @safe pure nothrow @nogc
    {
        this.id = id;
        _hasLocation = true;
        _location = location;
    }

public:
    /** Whether this Way node reference carries an exact location. */
    pragma(inline, true)
    @property bool hasLocation() const @safe pure nothrow @nogc
    {
        return _hasLocation;
    }

    /**
     * Exact semantic location carried alongside this node reference.
     *
     * The property is valid only when `hasLocation` is true.
     */
    pragma(inline, true)
    @property LocationView location() const @safe pure nothrow @nogc
    in (hasLocation)
    {
        return _location;
    }
}

unittest
{
    const node = WayNodeView(42);
    assert(node.id == 42);
    assert(!node.hasLocation);
}

unittest
{
    const expected = LocationView(48_208_174_300L, 16_373_818_900L);
    const node = WayNodeView(42, expected);

    assert(node.id == 42);
    assert(node.hasLocation);
    assert(node.location.latitudeNanodegrees == expected.latitudeNanodegrees);
    assert(node.location.longitudeNanodegrees == expected.longitudeNanodegrees);
}
