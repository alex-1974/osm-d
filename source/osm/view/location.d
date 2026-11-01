/**
 * Format-independent semantic OpenStreetMap locations.
 *
 * LocationView carries exact signed nanodegree coordinates while exposing
 * ordinary latitude/longitude values in degrees on demand. It owns only two
 * scalar integers: no source buffer is retained and no allocation is required.
 *
 * The exact integer accessors are available for consumers that must preserve
 * the decoded OSMPBF coordinate value without floating-point conversion.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-01
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.view.location;

/** Exact semantic OSM location with lazy degree conversion. */
struct LocationView
{
private:
    long _latitudeNanodegrees;
    long _longitudeNanodegrees;

public:
    /**
     * Construct a location from exact signed nanodegree coordinates.
     *
     * Params:
     *   latitudeNanodegrees = Latitude multiplied by 1,000,000,000.
     *   longitudeNanodegrees = Longitude multiplied by 1,000,000,000.
     */
    this(long latitudeNanodegrees, long longitudeNanodegrees)
        @safe pure nothrow @nogc
    {
        _latitudeNanodegrees = latitudeNanodegrees;
        _longitudeNanodegrees = longitudeNanodegrees;
    }

    /** Exact latitude in signed nanodegrees. */
    pragma(inline, true)
    @property long latitudeNanodegrees() const
        @safe pure nothrow @nogc
    {
        return _latitudeNanodegrees;
    }

    /** Exact longitude in signed nanodegrees. */
    pragma(inline, true)
    @property long longitudeNanodegrees() const
        @safe pure nothrow @nogc
    {
        return _longitudeNanodegrees;
    }

    /**
     * Latitude in degrees.
     *
     * The conversion happens only when this property is evaluated. Use
     * latitudeNanodegrees when exact integer preservation is required.
     */
    pragma(inline, true)
    @property double latitude() const
        @safe pure nothrow @nogc
    {
        return cast(double)_latitudeNanodegrees / 1_000_000_000.0;
    }

    /**
     * Longitude in degrees.
     *
     * The conversion happens only when this property is evaluated. Use
     * longitudeNanodegrees when exact integer preservation is required.
     */
    pragma(inline, true)
    @property double longitude() const
        @safe pure nothrow @nogc
    {
        return cast(double)_longitudeNanodegrees / 1_000_000_000.0;
    }

    /**
     * Compatibility accessor for the current low-level PBF coordinate name.
     *
     * Prefer latitudeNanodegrees in new semantic consumer code.
     */
    pragma(inline, true)
    @property long latNano() const
        @safe pure nothrow @nogc
    {
        return _latitudeNanodegrees;
    }

    /**
     * Compatibility accessor for the current low-level PBF coordinate name.
     *
     * Prefer longitudeNanodegrees in new semantic consumer code.
     */
    pragma(inline, true)
    @property long lonNano() const
        @safe pure nothrow @nogc
    {
        return _longitudeNanodegrees;
    }
}

unittest
{
    const location = LocationView(48_208_174_300L, 16_373_818_900L);

    assert(location.latitudeNanodegrees == 48_208_174_300L);
    assert(location.longitudeNanodegrees == 16_373_818_900L);
    assert(location.latNano == location.latitudeNanodegrees);
    assert(location.lonNano == location.longitudeNanodegrees);

    assert(location.latitude > 48.208174299 &&
           location.latitude < 48.208174301);
    assert(location.longitude > 16.373818899 &&
           location.longitude < 16.373818901);
}

unittest
{
    const origin = LocationView(0, 0);
    assert(origin.latitude == 0.0);
    assert(origin.longitude == 0.0);

    const negative = LocationView(-90_000_000_000L, -180_000_000_000L);
    assert(negative.latitude == -90.0);
    assert(negative.longitude == -180.0);
}
