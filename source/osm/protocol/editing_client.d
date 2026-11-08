
/**
 * OSM Editing API 0.6 protocol client.
 *
 * This module owns OSM endpoint paths, methods, media semantics, response
 * selection and OSM-aware HTTP status classification. Generic HTTP execution,
 * TLS and backend details remain behind transport.exchange.HttpExchange.
 *
 * The client never retains authorization credentials. Write operations accept
 * the complete Authorization header value only for the duration of one call.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-08
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.protocol.editing_client;

import osm.protocol.editing_permissions :
    EditingApiPermissions,
    EditingApiPermissionsReadStatus,
    readEditingApiPermissions;
import osm.history :
    HistoricalNodeVersion,
    HistoricalRelationVersion,
    HistoricalWayVersion,
    HistoryCoverage,
    HistoryError,
    HistoryStatus,
    NodeHistory,
    RelationHistory,
    WayHistory;
import osm.io.history.reader :
    readNodeHistoryXml,
    readRelationHistoryXml,
    readWayHistoryXml;
import osm.io.capabilities.document : EditingApiCapabilitiesDocument;
import osm.io.capabilities.reader :
    ApiCapabilitiesReadStatus,
    readEditingApiCapabilities;
import osm.io.changeset.reader :
    ChangesetReadStatus,
    readChangesetXml = readChangeset;
import osm.io.changeset.writer :
    ChangesetWriteStatus,
    writeChangesetTagRequest;
import osm.io.osmchange.writer :
    OsmChangeWriteStatus,
    OsmChangeWriter;
import osm.io.upload.reader :
    UploadResultReadStatus,
    readUploadResultXml = readUploadResult;
import osm.io.xml.document : OsmXmlDocument;
import osm.io.xml.reader :
    OsmXmlReadStatus,
    readOsmXmlDocument;
import osm.model.change :
    OwnedChangeSequence,
    UploadResult;
import osm.model.changeset :
    ChangesetId,
    ChangesetTagRequest,
    OwnedChangeset;
import osm.model.owned :
    OwnedBytes,
    OwnedDataset,
    OwnedNode,
    OwnedRelation,
    OwnedWay;
import osm.view.element :
    OsmId;
import std.conv : to;
import transport.buffer : SegmentedByteBuffer;
import transport.exchange :
    HttpExchange,
    HttpExchangeErrorKind,
    HttpExchangeLimits,
    HttpExchangeOptions,
    HttpMethod,
    HttpRequest,
    HttpResponse;
import transport.source :
    ByteRange,
    ByteSource,
    ReadError,
    ReadFailure,
    ReadLimits,
    ReadResult,
    ReadValue,
    SourceInfo,
    valid;

/** Explicit API 0.6 server base chosen by the caller. */
struct EditingApiServer
{
private:
    string baseUrl_;

public:
    /**
     * Construct a server from an API-version base URL.
     *
     * Example:
     * ---
     * auto server = EditingApiServer(
     *     "https://api.openstreetmap.org/api/0.6");
     * ---
     *
     * Trailing slashes are removed. No production server is selected
     * implicitly by osm-d.
     */
    this(string apiBaseUrl) @safe pure nothrow
    {
        while (apiBaseUrl.length &&
               apiBaseUrl[$ - 1] == '/')
            apiBaseUrl = apiBaseUrl[0 .. $ - 1];
        baseUrl_ = apiBaseUrl;
    }

    @property string baseUrl() const @safe pure nothrow @nogc
    {
        return baseUrl_;
    }

    @property bool valid() const @safe pure nothrow @nogc
    {
        return baseUrl_.length != 0;
    }
}

/** High-level layer at which an Editing API operation failed. */
enum EditingApiFailure : ubyte
{
    none,
    localValidation,
    requestEncoding,
    transport,
    http,
    responseDecoding,
}

/** OSM-aware classification of a completed non-success HTTP response. */
enum EditingApiServerError : ubyte
{
    none,
    badRequest,
    unauthorized,
    forbidden,
    notFound,
    methodNotAllowed,
    conflict,
    gone,
    preconditionFailed,
    payloadTooLarge,
    rateLimited,
    serviceUnavailable,
    bandwidthLimitExceeded,
    other,
}

/** Response semantic expected by the operation that produced a status. */
enum EditingApiResponseKind : ubyte
{
    none,
    capabilities,
    permissions,
    osmXml,
    changeset,
    changesetId,
    uploadResult,
    empty,
}

/**
 * Stable protocol diagnostic for one Editing API operation.
 *
 * transportError is meaningful only when hasTransportError is true.
 * serverError is meaningful when failure is EditingApiFailure.http.
 * A completed 4xx/5xx response therefore remains distinct from a network/TLS
 * failure.
 */
struct EditingApiStatus
{
    EditingApiFailure failure = EditingApiFailure.none;
    EditingApiResponseKind responseKind = EditingApiResponseKind.none;

    bool hasTransportError;
    HttpExchangeErrorKind transportError;

    bool hasHttpStatus;
    ushort httpStatus;
    EditingApiServerError serverError = EditingApiServerError.none;

    /**
     * Non-secret HTTP reason phrase retained for a completed response.
     *
     * It is empty when no HTTP response was received.
     */
    string httpReason;

    /**
     * Bounded prefix of a non-success response body.
     *
     * The prefix is copied into owned immutable storage only for HTTP
     * responses that fail the OSM operation. It is never populated from
     * request headers or request bodies.
     */
    OwnedBytes diagnosticBody;

    /// True when diagnosticBody is only a prefix of a larger response body.
    bool diagnosticBodyTruncated;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return failure == EditingApiFailure.none;
    }
}

/**
 * Synchronous OSM Editing API 0.6 protocol client.
 *
 * The injected exchange is retained, but authorization is not. The application
 * remains responsible for account selection, token refresh, retry/backoff,
 * changeset lifecycle policy and asynchronous scheduling.
 */
final class EditingApiClient
{
private:
    EditingApiServer server_;
    HttpExchange backend_;
    HttpExchangeLimits limits_;
    HttpExchangeOptions options_;

public:
    /**
     * Construct a client over a generic transport-d HTTP exchange.
     *
     * Params:
     *   server = Explicit API 0.6 base URL.
     *   backend = Generic synchronous HTTP exchange. May be a deterministic
     *             fake for tests or CurlHttpExchange for real HTTP.
     *   limits = Generic bounded request/response limits.
     *   options = Generic timeout/redirect/user-agent transport options.
     */
    this(
        EditingApiServer server,
        HttpExchange backend,
        HttpExchangeLimits limits = HttpExchangeLimits.init,
        HttpExchangeOptions options = HttpExchangeOptions.init)
        @safe
    {
        server_ = server;
        backend_ = backend;
        limits_ = limits;
        options_ = options;
    }

    @property EditingApiServer server() const
        @safe pure nothrow @nogc
    {
        return server_;
    }

    /**
     * Read dynamic server capabilities and upload limits.
     *
     * OSM operation: GET /capabilities; authorization is not required.
     * The XML response is bounded by the configured transport limits and
     * materialized into an owning EditingApiCapabilitiesDocument.
     * Returns true only for HTTP 200 plus a valid capability document;
     * status separates exchange, HTTP and response-decoding failures.
     */
    bool readCapabilities(
        out EditingApiCapabilitiesDocument document,
        out EditingApiStatus status)
        @safe
    {
        document = EditingApiCapabilitiesDocument.init;
        begin(status, EditingApiResponseKind.capabilities);

        HttpResponse response;
        if (!get("/capabilities", null, response, status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        ApiCapabilitiesReadStatus codec;
        if (!readEditingApiCapabilities(source, document, codec))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read permissions granted to the current connection.
     *
     * OSM operation: GET /permissions. Authorization is optional; an empty
     * authorizationHeader performs an anonymous request and the supplied value
     * is never retained by the client.
     * The XML response is bounded and materialized into owning permission
     * names, preserving unknown future names.
     * Returns true only for HTTP 200 plus a valid permissions document.
     */
    bool readPermissions(
        out EditingApiPermissions permissions,
        out EditingApiStatus status,
        string authorizationHeader = null)
        @safe
    {
        permissions = EditingApiPermissions.init;
        begin(status, EditingApiResponseKind.permissions);

        HttpResponse response;
        if (!get(
                "/permissions",
                authorizationHeader,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        EditingApiPermissionsReadStatus codec;
        if (!readEditingApiPermissions(source, permissions, codec))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read the current version of one Node.
     *
     * OSM operation: GET /node/{id}; no authorization is required.
     * The application/xml response is bounded and materialized as an OwnedNode.
     * Returns false for an invalid ID, exchange failure, non-200 HTTP response,
     * malformed/unsupported XML, or a response that is not exactly that Node.
     */
    bool readNode(
        OsmId id,
        out OwnedNode node,
        out EditingApiStatus status)
        @safe
    {
        node = OwnedNode.init;
        if (!prepareReadId(id, status))
            return false;

        OsmXmlDocument document;
        if (!readElementDocument(
                "/node/" ~ id.to!string,
                document,
                status))
            return false;

        if (document.data.nodes.length != 1 ||
            document.data.ways.length != 0 ||
            document.data.relations.length != 0 ||
            document.data.nodes[0].id != id)
            return decodeFailure(status);

        node = document.data.nodes[0];
        return true;
    }

    /**
     * Read one historical Node version.
     *
     * OSM operation: GET /node/{id}/{version}; no authorization is required.
     * The historical result preserves visible=false and permits location to be
     * absent for a deleted version instead of inventing coordinates.
     */
    bool readNodeVersion(
        OsmId id,
        int versionNumber,
        out HistoricalNodeVersion node,
        out EditingApiStatus status)
        @safe
    {
        node = HistoricalNodeVersion.init;
        if (!prepareReadVersion(id, versionNumber, status))
            return false;

        HttpResponse response;
        if (!get(
                "/node/" ~ id.to!string ~ "/" ~
                    versionNumber.to!string,
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalNodeVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readNodeHistoryXml(source, versions, codec) ||
            versions.length != 1 ||
            versions[0].id != id ||
            !versions[0].metadata.hasVersion ||
            versions[0].metadata.versionNumber != versionNumber)
            return decodeFailure(status);

        node = versions[0].deepCopy();
        return true;
    }

    /**
     * Read the authoritative history of one Node.
     *
     * OSM operation: GET /node/{id}/history; no authorization is required.
     * Deleted versions are represented explicitly and may omit location when
     * the server omits lat/lon for visible=false. The returned history is
     * complete when versions are contiguous from 1, otherwise partial (for
     * example when inaccessible/redacted versions create a gap).
     */
    bool readNodeHistory(
        OsmId id,
        out NodeHistory history,
        out EditingApiStatus status)
        @safe
    {
        history = NodeHistory.init;
        if (!prepareReadId(id, status))
            return false;

        HttpResponse response;
        if (!get(
                "/node/" ~ id.to!string ~ "/history",
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalNodeVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readNodeHistoryXml(source, versions, codec))
            return decodeFailure(status);

        foreach (ref const value; versions)
            if (value.id != id)
                return decodeFailure(status);

        if (!buildServerHistory(versions, history))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read the current version of one Way.
     *
     * OSM operation: GET /way/{id}; no authorization is required.
     * The bounded XML response is materialized into an OwnedWay and checked
     * against the requested identity. Failure details are returned in status.
     */
    bool readWay(
        OsmId id,
        out OwnedWay way,
        out EditingApiStatus status)
        @safe
    {
        way = OwnedWay.init;
        if (!prepareReadId(id, status))
            return false;

        OsmXmlDocument document;
        if (!readElementDocument(
                "/way/" ~ id.to!string,
                document,
                status))
            return false;

        if (document.data.nodes.length != 0 ||
            document.data.ways.length != 1 ||
            document.data.relations.length != 0 ||
            document.data.ways[0].id != id)
            return decodeFailure(status);

        way = document.data.ways[0];
        return true;
    }

    /**
     * Read one historical Way version.
     *
     * OSM operation: GET /way/{id}/{version}; no authorization is required.
     * The result is historical rather than a live OwnedWay so visibility and
     * deletion semantics remain explicit.
     */
    bool readWayVersion(
        OsmId id,
        int versionNumber,
        out HistoricalWayVersion way,
        out EditingApiStatus status)
        @safe
    {
        way = HistoricalWayVersion.init;
        if (!prepareReadVersion(id, versionNumber, status))
            return false;

        HttpResponse response;
        if (!get(
                "/way/" ~ id.to!string ~ "/" ~
                    versionNumber.to!string,
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalWayVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readWayHistoryXml(source, versions, codec) ||
            versions.length != 1 ||
            versions[0].id != id ||
            !versions[0].metadata.hasVersion ||
            versions[0].metadata.versionNumber != versionNumber)
            return decodeFailure(status);

        way = versions[0].deepCopy();
        return true;
    }

    /**
     * Read the authoritative history of one Way.
     *
     * OSM operation: GET /way/{id}/history; no authorization is required.
     * Ordering, duplicates, visibility and any version gaps are preserved.
     */
    bool readWayHistory(
        OsmId id,
        out WayHistory history,
        out EditingApiStatus status)
        @safe
    {
        history = WayHistory.init;
        if (!prepareReadId(id, status))
            return false;

        HttpResponse response;
        if (!get(
                "/way/" ~ id.to!string ~ "/history",
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalWayVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readWayHistoryXml(source, versions, codec))
            return decodeFailure(status);

        foreach (ref const value; versions)
            if (value.id != id)
                return decodeFailure(status);

        if (!buildServerHistory(versions, history))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read one Way plus the Nodes returned by the full expansion endpoint.
     *
     * OSM operation: GET /way/{id}/full; no authorization is required.
     * The bounded XML response is returned as an owning OwnedDataset; the
     * requested Way must occur exactly once and Relation content is rejected.
     */
    bool readWayFull(
        OsmId id,
        out OwnedDataset dataset,
        out EditingApiStatus status)
        @safe
    {
        dataset = OwnedDataset.init;
        if (!prepareReadId(id, status))
            return false;

        OsmXmlDocument document;
        if (!readElementDocument(
                "/way/" ~ id.to!string ~ "/full",
                document,
                status))
            return false;

        if (document.data.ways.length != 1 ||
            document.data.ways[0].id != id ||
            document.data.relations.length != 0)
            return decodeFailure(status);

        dataset = document.data;
        return true;
    }

    /**
     * Read the current version of one Relation.
     *
     * OSM operation: GET /relation/{id}; no authorization is required.
     * The bounded XML response becomes an OwnedRelation checked against the
     * requested identity.
     */
    bool readRelation(
        OsmId id,
        out OwnedRelation relation,
        out EditingApiStatus status)
        @safe
    {
        relation = OwnedRelation.init;
        if (!prepareReadId(id, status))
            return false;

        OsmXmlDocument document;
        if (!readElementDocument(
                "/relation/" ~ id.to!string,
                document,
                status))
            return false;

        if (document.data.nodes.length != 0 ||
            document.data.ways.length != 0 ||
            document.data.relations.length != 1 ||
            document.data.relations[0].id != id)
            return decodeFailure(status);

        relation = document.data.relations[0];
        return true;
    }

    /**
     * Read one historical Relation version.
     *
     * OSM operation: GET /relation/{id}/{version}; no authorization is required.
     * Ordered members, roles, tags and visibility are retained as historical
     * data rather than implying a current live object.
     */
    bool readRelationVersion(
        OsmId id,
        int versionNumber,
        out HistoricalRelationVersion relation,
        out EditingApiStatus status)
        @safe
    {
        relation = HistoricalRelationVersion.init;
        if (!prepareReadVersion(id, versionNumber, status))
            return false;

        HttpResponse response;
        if (!get(
                "/relation/" ~ id.to!string ~ "/" ~
                    versionNumber.to!string,
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalRelationVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readRelationHistoryXml(source, versions, codec) ||
            versions.length != 1 ||
            versions[0].id != id ||
            !versions[0].metadata.hasVersion ||
            versions[0].metadata.versionNumber != versionNumber)
            return decodeFailure(status);

        relation = versions[0].deepCopy();
        return true;
    }

    /**
     * Read the authoritative history of one Relation.
     *
     * OSM operation: GET /relation/{id}/history; no authorization is required.
     * Ordered typed members, roles, tags, visibility and version gaps are
     * preserved in the history model.
     */
    bool readRelationHistory(
        OsmId id,
        out RelationHistory history,
        out EditingApiStatus status)
        @safe
    {
        history = RelationHistory.init;
        if (!prepareReadId(id, status))
            return false;

        HttpResponse response;
        if (!get(
                "/relation/" ~ id.to!string ~ "/history",
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        HistoricalRelationVersion[] versions;
        OsmXmlReadStatus codec;
        if (!readRelationHistoryXml(source, versions, codec))
            return decodeFailure(status);

        foreach (ref const value; versions)
            if (value.id != id)
                return decodeFailure(status);

        if (!buildServerHistory(versions, history))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read one Relation plus the server's full member expansion.
     *
     * OSM operation: GET /relation/{id}/full; no authorization is required.
     * The bounded XML response is returned as an owning OwnedDataset and must
     * contain the requested Relation. Expansion depth follows server semantics.
     */
    bool readRelationFull(
        OsmId id,
        out OwnedDataset dataset,
        out EditingApiStatus status)
        @safe
    {
        dataset = OwnedDataset.init;
        if (!prepareReadId(id, status))
            return false;

        OsmXmlDocument document;
        if (!readElementDocument(
                "/relation/" ~ id.to!string ~ "/full",
                document,
                status))
            return false;

        bool found;
        foreach (ref const relation; document.data.relations)
        {
            if (relation.id == id)
            {
                found = true;
                break;
            }
        }

        if (!found)
            return decodeFailure(status);

        dataset = document.data;
        return true;
    }

    /**
     * Create a Changeset and return the server-assigned positive ID.
     *
     * OSM operation: PUT /changeset/create with text/xml request content and a
     * text/plain response. Authorization is required and request-scoped; the
     * supplied header is placed only in transport-d sensitiveHeaders and is not
     * retained by this client.
     * The tag request is encoded directly into bounded segmented storage.
     * Returns true only for HTTP 200 plus a valid positive Changeset ID.
     */
    bool createChangeset(
        ref const ChangesetTagRequest request,
        string authorizationHeader,
        out ChangesetId id,
        out EditingApiStatus status)
        @safe
    {
        id = ChangesetId.init;
        begin(status, EditingApiResponseKind.changesetId);

        if (!prepareWrite(authorizationHeader, status))
            return false;

        SegmentedByteBuffer body;
        if (!encodeChangesetRequest(request, body, status))
            return false;

        HttpResponse response;
        if (!execute(
                HttpMethod.put,
                "/changeset/create",
                "text/plain",
                "text/xml; charset=utf-8",
                body,
                authorizationHeader,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        if (!parseChangesetId(response.body, id))
            return decodeFailure(status);

        return true;
    }

    /**
     * Read one Changeset and its current server-managed state.
     *
     * OSM operation: GET /changeset/{id}; no authorization is required.
     * The bounded XML response is materialized as an OwnedChangeset and its
     * server ID is checked against the request.
     */
    bool readChangeset(
        ChangesetId id,
        out OwnedChangeset changeset,
        out EditingApiStatus status)
        @safe
    {
        changeset = OwnedChangeset.init;
        begin(status, EditingApiResponseKind.changeset);

        if (id <= 0)
            return localFailure(status);

        HttpResponse response;
        if (!get(
                "/changeset/" ~ id.to!string,
                null,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        ChangesetReadStatus codec;
        if (!readChangesetXml(source, changeset, codec) ||
            !changeset.hasId ||
            changeset.id != id)
            return decodeFailure(status);

        return true;
    }

    /**
     * Replace all Changeset tags and return the updated representation.
     *
     * OSM operation: PUT /changeset/{id} with text/xml request content and an
     * XML Changeset response. Authorization is required and not retained.
     * The request contains only ChangesetTagRequest fields; server-managed
     * identity/timestamps/bounds/counters are never serialized as writable
     * state. HTTP conflict remains an HTTP/OSM status, not a transport failure.
     */
    bool updateChangeset(
        ChangesetId id,
        ref const ChangesetTagRequest request,
        string authorizationHeader,
        out OwnedChangeset changeset,
        out EditingApiStatus status)
        @safe
    {
        changeset = OwnedChangeset.init;
        begin(status, EditingApiResponseKind.changeset);

        if (id <= 0)
            return localFailure(status);
        if (!prepareWrite(authorizationHeader, status))
            return false;

        SegmentedByteBuffer body;
        if (!encodeChangesetRequest(request, body, status))
            return false;

        HttpResponse response;
        if (!execute(
                HttpMethod.put,
                "/changeset/" ~ id.to!string,
                "application/xml",
                "text/xml; charset=utf-8",
                body,
                authorizationHeader,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        ChangesetReadStatus codec;
        if (!readChangesetXml(source, changeset, codec) ||
            !changeset.hasId ||
            changeset.id != id)
            return decodeFailure(status);

        return true;
    }

    /**
     * Close one Changeset.
     *
     * OSM operation: PUT /changeset/{id}/close. Authorization is required and
     * not retained. HTTP 200 is success and no response body is required.
     * A completed 409/404/etc. remains a classified HTTP response with bounded
     * diagnostic data in status.
     */
    bool closeChangeset(
        ChangesetId id,
        string authorizationHeader,
        out EditingApiStatus status)
        @safe
    {
        begin(status, EditingApiResponseKind.empty);

        if (id <= 0)
            return localFailure(status);
        if (!prepareWrite(authorizationHeader, status))
            return false;

        HttpResponse response;
        if (!execute(
                HttpMethod.put,
                "/changeset/" ~ id.to!string ~ "/close",
                null,
                null,
                null,
                authorizationHeader,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        return true;
    }

    /**
     * Upload one atomic osmChange diff and parse the returned diffResult.
     *
     * OSM operation: POST /changeset/{id}/upload with text/xml osmChange
     * content and an XML diffResult response. Authorization is required and is
     * not retained. Every entry must already carry the same Changeset ID.
     * Request and response bodies remain bounded and segmented; the successful
     * response is materialized as an owning UploadResult.
     */
    bool uploadChanges(
        ChangesetId id,
        ref const OwnedChangeSequence changes,
        string authorizationHeader,
        out UploadResult result,
        out EditingApiStatus status)
        @safe
    {
        result = UploadResult.init;
        begin(status, EditingApiResponseKind.uploadResult);

        if (id <= 0)
            return localFailure(status);
        if (!prepareWrite(authorizationHeader, status))
            return false;

        foreach (ref const entry; changes.entries)
        {
            if (!entry.metadata.hasChangeset ||
                entry.metadata.changesetId != id)
                return localFailure(status);
        }

        SegmentedByteBuffer body;
        if (!encodeChanges(changes, body, status))
            return false;

        HttpResponse response;
        if (!execute(
                HttpMethod.post,
                "/changeset/" ~ id.to!string ~ "/upload",
                "application/xml",
                "text/xml; charset=utf-8",
                body,
                authorizationHeader,
                response,
                status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        UploadResultReadStatus codec;
        if (!readUploadResultXml(source, result, codec))
            return decodeFailure(status);

        return true;
    }

private:
    void begin(
        out EditingApiStatus status,
        EditingApiResponseKind kind)
        @safe pure nothrow @nogc
    {
        status = EditingApiStatus.init;
        status.responseKind = kind;
    }

    bool prepareReadId(
        OsmId id,
        out EditingApiStatus status)
        @safe pure nothrow @nogc
    {
        begin(status, EditingApiResponseKind.osmXml);
        if (id <= 0)
            return localFailure(status);
        return true;
    }

    bool prepareReadVersion(
        OsmId id,
        int versionNumber,
        out EditingApiStatus status)
        @safe pure nothrow @nogc
    {
        begin(status, EditingApiResponseKind.osmXml);
        if (id <= 0 || versionNumber <= 0)
            return localFailure(status);
        return true;
    }

    bool prepareWrite(
        string authorizationHeader,
        ref EditingApiStatus status)
        @safe pure nothrow @nogc
    {
        if (!server_.valid ||
            backend_ is null ||
            authorizationHeader.length == 0)
            return localFailure(status);
        return true;
    }

    bool get(
        string path,
        string authorizationHeader,
        out HttpResponse response,
        ref EditingApiStatus status)
        @safe
    {
        return execute(
            HttpMethod.get,
            path,
            "application/xml",
            null,
            null,
            authorizationHeader,
            response,
            status);
    }

    bool execute(
        HttpMethod method,
        string path,
        string accept,
        string contentType,
        SegmentedByteBuffer body,
        string authorizationHeader,
        out HttpResponse response,
        ref EditingApiStatus status)
        @safe
    {
        response = HttpResponse.init;

        if (!server_.valid || backend_ is null)
            return localFailure(status);

        HttpRequest request;
        request.method = method;
        request.url = server_.baseUrl ~ path;
        request.limits = limits_;
        request.options = options_;
        request.body = body;

        if (accept.length)
            request.headers["Accept"] = accept;
        if (contentType.length)
            request.headers["Content-Type"] = contentType;
        if (authorizationHeader.length)
            request.sensitiveHeaders["Authorization"] =
                authorizationHeader;

        auto exchanged = backend_.exchange(request);
        if (exchanged.hasError)
        {
            status.failure = EditingApiFailure.transport;
            status.hasTransportError = true;
            status.transportError = exchanged.error.kind;
            return false;
        }

        response = exchanged.value;
        status.hasHttpStatus = true;
        status.httpStatus = response.statusCode;
        return true;
    }

    bool requireOk(
        ref const HttpResponse response,
        ref EditingApiStatus status)
        @safe
    {
        if (response.statusCode == 200)
            return true;

        status.failure = EditingApiFailure.http;
        status.serverError = classifyServerError(response.statusCode);
        status.httpReason = response.reason.idup;
        captureHttpDiagnostic(response.body, status);
        return false;
    }

    bool readElementDocument(
        string path,
        out OsmXmlDocument document,
        out EditingApiStatus status)
        @safe
    {
        document = OsmXmlDocument.init;
        begin(status, EditingApiResponseKind.osmXml);

        HttpResponse response;
        if (!get(path, null, response, status) ||
            !requireOk(response, status))
            return false;

        auto source = new ResponseBodySource(response.body);
        OsmXmlReadStatus codec;
        if (!readOsmXmlDocument(source, document, codec))
            return decodeFailure(status);

        return true;
    }

    bool encodeChangesetRequest(
        ref const ChangesetTagRequest request,
        out SegmentedByteBuffer body,
        ref EditingApiStatus status)
        @safe
    {
        body = newRequestBody();
        ChangesetWriteStatus codec;
        if (!writeChangesetTagRequest(request, body, codec))
        {
            status.failure = EditingApiFailure.requestEncoding;
            return false;
        }
        return true;
    }

    bool encodeChanges(
        ref const OwnedChangeSequence changes,
        out SegmentedByteBuffer body,
        ref EditingApiStatus status)
        @safe
    {
        body = newRequestBody();
        OsmChangeWriter writer;
        OsmChangeWriteStatus codec;
        if (!writer.writeChanges(changes, body, codec))
        {
            status.failure = EditingApiFailure.requestEncoding;
            return false;
        }
        return true;
    }

    SegmentedByteBuffer newRequestBody() @safe
    {
        size_t chunkSize = 64 * 1024;
        if (limits_.maximumRequestBytes != 0 &&
            limits_.maximumRequestBytes < chunkSize)
            chunkSize = limits_.maximumRequestBytes;
        if (chunkSize == 0)
            chunkSize = 1;

        return new SegmentedByteBuffer(
            chunkSize,
            limits_.maximumRequestBytes);
    }
}

private:

bool localFailure(ref EditingApiStatus status)
    @safe pure nothrow @nogc
{
    status.failure = EditingApiFailure.localValidation;
    return false;
}

bool decodeFailure(ref EditingApiStatus status)
    @safe pure nothrow @nogc
{
    status.failure = EditingApiFailure.responseDecoding;
    return false;
}

bool matchesVersion(bool present, int actual, int expected)
    @safe pure nothrow @nogc
{
    return present && actual == expected;
}

bool buildServerHistory(H, V)(
    scope const(V)[] versions,
    out H history) @safe
{
    HistoryStatus historyStatus;
    if (H.create(
            versions,
            HistoryCoverage.complete,
            history,
            historyStatus))
        return true;

    if (historyStatus.error != HistoryError.incompleteSequence)
        return false;

    return H.create(
        versions,
        HistoryCoverage.partial,
        history,
        historyStatus);
}

enum size_t maximumHttpDiagnosticBytes = 4 * 1024;

void captureHttpDiagnostic(
    const(SegmentedByteBuffer) body,
    ref EditingApiStatus status)
    @safe
{
    status.diagnosticBody = null;
    status.diagnosticBodyTruncated = false;

    if (body is null || body.length == 0)
        return;

    size_t retained = body.length;
    if (retained > maximumHttpDiagnosticBytes)
    {
        retained = maximumHttpDiagnosticBytes;
        status.diagnosticBodyTruncated = true;
    }

    auto scratch = new ubyte[retained];
    size_t written;
    foreach (chunk; body.chunks)
    {
        if (written == retained)
            break;

        size_t count = chunk.length;
        if (count > retained - written)
            count = retained - written;

        scratch[written .. written + count] = chunk[0 .. count];
        written += count;
    }

    status.diagnosticBody = scratch.idup;
}

EditingApiServerError classifyServerError(ushort code)
    @safe pure nothrow @nogc
{
    switch (code)
    {
        case 400: return EditingApiServerError.badRequest;
        case 401: return EditingApiServerError.unauthorized;
        case 403: return EditingApiServerError.forbidden;
        case 404: return EditingApiServerError.notFound;
        case 405: return EditingApiServerError.methodNotAllowed;
        case 409: return EditingApiServerError.conflict;
        case 410: return EditingApiServerError.gone;
        case 412: return EditingApiServerError.preconditionFailed;
        case 413: return EditingApiServerError.payloadTooLarge;
        case 429: return EditingApiServerError.rateLimited;
        case 503: return EditingApiServerError.serviceUnavailable;
        case 509: return EditingApiServerError.bandwidthLimitExceeded;
        default:  return EditingApiServerError.other;
    }
}

bool parseChangesetId(
    SegmentedByteBuffer body,
    out ChangesetId id)
    @safe
{
    id = ChangesetId.init;
    if (body is null)
        return false;

    ulong value;
    bool sawDigit;
    bool trailingWhitespace;

    foreach (chunk; body.chunks)
    {
        foreach (byteValue; chunk)
        {
            if (byteValue >= '0' && byteValue <= '9')
            {
                if (trailingWhitespace)
                    return false;

                const digit = cast(ulong)(byteValue - '0');
                if (value >
                    (cast(ulong) long.max - digit) / 10)
                    return false;

                value = value * 10 + digit;
                sawDigit = true;
                continue;
            }

            if (byteValue == ' ' ||
                byteValue == '\t' ||
                byteValue == '\r' ||
                byteValue == '\n')
            {
                if (sawDigit)
                    trailingWhitespace = true;
                continue;
            }

            return false;
        }
    }

    if (!sawDigit || value == 0 ||
        value > cast(ulong) long.max)
        return false;

    id = cast(ChangesetId) value;
    return true;
}

/**
 * ByteSource adapter over transport-d's segmented response body.
 *
 * It keeps the owning SegmentedByteBuffer alive and exposes bounded random or
 * sequential reads without flattening the body into one allocation.
 */
final class ResponseBodySource : ByteSource
{
private:
    SegmentedByteBuffer body_;
    const(ubyte)[][] chunks_;
    size_t length_;

public:
    this(SegmentedByteBuffer body) @safe
    {
        body_ = body;
        if (body_ !is null)
        {
            chunks_ = body_.chunks;
            length_ = body_.length;
        }
    }

    @property SourceInfo sourceInfo() const @safe pure nothrow
    {
        return SourceInfo(
            "editing-api-response",
            "memory",
            true,
            length_,
            true);
    }

    ReadResult read(
        ByteRange range,
        scope ubyte[] destination,
        ReadLimits limits = ReadLimits.init)
        @safe
    {
        if (!valid(range))
            return ReadResult.failure(
                ReadFailure(ReadError.invalidRange, 0));
        if (range.length > limits.maximumBytes)
            return ReadResult.failure(
                ReadFailure(ReadError.limitExceeded, 0));
        if (destination.length < range.length)
            return ReadResult.failure(
                ReadFailure(ReadError.destinationTooSmall, 0));
        if (range.offset == length_)
            return ReadResult.failure(
                ReadFailure(ReadError.endOfSource, 0));
        if (range.offset > length_ ||
            range.length > length_ - cast(size_t) range.offset)
            return ReadResult.failure(
                ReadFailure(ReadError.invalidRange, 0));

        copyAt(
            cast(size_t) range.offset,
            destination[0 .. range.length]);
        return ReadResult.success(ReadValue(range.length));
    }

    ReadResult readSome(
        ulong offset,
        scope ubyte[] destination,
        ReadLimits limits = ReadLimits.init)
        @safe
    {
        if (destination.length > limits.maximumBytes)
            return ReadResult.failure(
                ReadFailure(ReadError.limitExceeded, 0));
        if (offset > length_)
            return ReadResult.failure(
                ReadFailure(ReadError.invalidRange, 0));
        if (offset == length_ || destination.length == 0)
            return ReadResult.failure(
                ReadFailure(ReadError.endOfSource, 0));

        size_t count = length_ - cast(size_t) offset;
        if (count > destination.length)
            count = destination.length;

        copyAt(
            cast(size_t) offset,
            destination[0 .. count]);
        return ReadResult.success(ReadValue(count));
    }

private:
    void copyAt(
        size_t offset,
        scope ubyte[] destination)
        @safe
    {
        size_t logicalOffset;
        size_t written;

        foreach (chunk; chunks_)
        {
            if (written == destination.length)
                break;

            if (offset >= logicalOffset + chunk.length)
            {
                logicalOffset += chunk.length;
                continue;
            }

            const start = offset > logicalOffset
                ? offset - logicalOffset
                : 0;
            size_t count = chunk.length - start;
            if (count > destination.length - written)
                count = destination.length - written;

            destination[written .. written + count] =
                chunk[start .. start + count];
            written += count;
            offset += count;
            logicalOffset += chunk.length;
        }

        assert(written == destination.length);
    }
}
