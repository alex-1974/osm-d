/**
 * Editing-relevant projection of the OSM API capabilities document.
 *
 * This model intentionally does not claim to represent every capability
 * advertised by an OSM server. It retains the API/version/status information
 * and upload limits needed by osm-d validation while unrelated capability
 * families remain outside this projection.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-04
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.io.capabilities.document;

import osm.model.owned : OwnedBytes;
import osm.validation.capability : CapabilityProfile;

/** Service availability state reported by the Editing API. */
enum ApiServiceState : ubyte
{
    /// No state was present in the projected document.
    unknown,
    online,
    readonly,
    offline,
}

/** Root metadata observed on one capabilities XML response. */
struct ApiCapabilitiesDocumentInfo
{
    bool hasVersion;
    OwnedBytes versionText;

    bool hasGenerator;
    OwnedBytes generator;

    bool hasCopyright;
    OwnedBytes copyrightText;

    bool hasAttribution;
    OwnedBytes attribution;

    bool hasLicense;
    OwnedBytes license;

    /**
     * Create an independently mutable metadata value.
     *
     * Returns:
     *   A value copy. Immutable byte strings may safely remain shared.
     */
    ApiCapabilitiesDocumentInfo deepCopy() const @safe
    {
        return this;
    }
}

/**
 * Editing/upload-relevant capability projection.
 *
 * uploadLimits maps directly to the existing target-aware validation model.
 * Version strings are retained exactly rather than reinterpreted as floating
 * point numbers.
 */
struct EditingApiCapabilities
{
    bool hasMinimumVersion;
    OwnedBytes minimumVersion;

    bool hasMaximumVersion;
    OwnedBytes maximumVersion;

    CapabilityProfile uploadLimits;

    bool hasTimeout;
    size_t timeoutSeconds;

    bool hasDatabaseState;
    ApiServiceState databaseState = ApiServiceState.unknown;

    bool hasApiState;
    ApiServiceState apiState = ApiServiceState.unknown;

    bool hasGpxState;
    ApiServiceState gpxState = ApiServiceState.unknown;

    /**
     * Return the validation-ready target upload limits.
     *
     * Returns:
     *   The discovered Way-node, Relation-member and Changeset-element limits.
     */
    @property CapabilityProfile validationProfile() const
        @safe pure nothrow @nogc
    {
        return uploadLimits;
    }
}

/** Materialized editing-capability response. */
struct EditingApiCapabilitiesDocument
{
    ApiCapabilitiesDocumentInfo info;
    EditingApiCapabilities capabilities;

    /**
     * Create an independently mutable document value.
     *
     * Returns:
     *   A value copy of the projected capability document.
     */
    EditingApiCapabilitiesDocument deepCopy() const @safe
    {
        EditingApiCapabilitiesDocument result = this;
        result.info = info.deepCopy();
        return result;
    }
}

unittest
{
    EditingApiCapabilities document;
    document.uploadLimits.maximumWayNodes = 2_000;
    document.uploadLimits.maximumRelationMembers = 32_000;
    document.uploadLimits.maximumChangesetElements = 10_000;

    const profile = document.validationProfile;
    assert(profile.maximumWayNodes == 2_000);
    assert(profile.maximumRelationMembers == 32_000);
    assert(profile.maximumChangesetElements == 10_000);
}
