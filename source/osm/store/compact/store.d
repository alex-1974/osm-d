/**
 * Compact in-memory editable OSM store implementation.
 *
 * The representation is deliberately data-oriented: fixed fields are stored in
 * columns, variable children in append-only pools, repeated strings in one
 * intern pool, and typed IDs in open-addressed indexes. Public callers see only
 * OSM semantics, stable handles and borrowed semantic views.
 *
 * Parent/reverse indexes are deliberately not exposed here; #63 owns their
 * production implementation and mutation-coherence contract.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.store.compact.store;

import core.atomic : atomicOp;
import core.exception : onArrayIndexError, onArraySliceError, onOutOfMemoryError;
import core.stdc.stdlib : free, realloc;
import core.stdc.string : memcpy;
import osm.model.owned :
    OwnedBytes,
    OwnedDataset,
    OwnedMetadata,
    OwnedNode,
    OwnedRelation,
    OwnedRelationMember,
    OwnedTag,
    OwnedWay,
    OwnedWayNode;
import osm.view.element : ElementType, OsmId;
import osm.view.location : LocationView;


/**
 * Small internal owner for trivially-copyable store columns.
 *
 * Allocation and pointer arithmetic are confined here. Public store methods
 * remain @safe and expose only bounds-checked values or borrowed slices whose
 * invalidation follows the documented store mutation contract.
 */
package(osm) struct ManualArray(T)
{
private:
    T* _ptr;
    size_t _length;
    size_t _capacity;

public:
    @disable this(this);

    ~this() @trusted nothrow @nogc
    {
        if (_ptr !is null)
            free(_ptr);
        _ptr = null;
        _length = 0;
        _capacity = 0;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return _length;
    }

    @property void length(size_t value) @trusted nothrow @nogc
    {
        if (value > _capacity)
            reserve(value);

        foreach (i; _length .. value)
            _ptr[i] = T.init;

        _length = value;
    }

    void reserve(size_t requested) @trusted nothrow @nogc
    {
        if (requested <= _capacity)
            return;

        if (T.sizeof != 0 && requested > size_t.max / T.sizeof)
            onOutOfMemoryError();

        auto memory = realloc(
            cast(void*)_ptr,
            requested * T.sizeof);
        if (memory is null)
            onOutOfMemoryError();

        _ptr = cast(T*)memory;
        _capacity = requested;
    }

    void append(T value) @trusted nothrow @nogc
    {
        ensureAppendCapacity(1);
        _ptr[_length++] = value;
    }

    void append(scope const(T)[] values) @trusted nothrow @nogc
    {
        if (values.length == 0)
            return;

        ensureAppendCapacity(values.length);
        memcpy(
            cast(void*)(_ptr + _length),
            cast(const(void)*)values.ptr,
            values.length * T.sizeof);
        _length += values.length;
    }

    ref ManualArray opOpAssign(string op : "~")(T value) @trusted nothrow @nogc
    {
        append(value);
        return this;
    }

    ref ManualArray opOpAssign(string op : "~")(scope const(T)[] values)
        @trusted nothrow @nogc
    {
        append(values);
        return this;
    }

    ref T opIndex(size_t index) @trusted nothrow @nogc
    {
        if (index >= _length)
            onArrayIndexError(index, _length);
        return _ptr[index];
    }

    ref const(T) opIndex(size_t index) const @trusted nothrow @nogc
    {
        if (index >= _length)
            onArrayIndexError(index, _length);
        return _ptr[index];
    }

    T[] opSlice() @trusted nothrow @nogc
    {
        return _ptr[0 .. _length];
    }

    const(T)[] opSlice() const @trusted nothrow @nogc
    {
        return _ptr[0 .. _length];
    }

    T[] opSlice(size_t lower, size_t upper) @trusted nothrow @nogc
    {
        if (lower > upper || upper > _length)
            onArraySliceError(lower, upper, _length);
        return _ptr[lower .. upper];
    }

    const(T)[] opSlice(size_t lower, size_t upper) const @trusted nothrow @nogc
    {
        if (lower > upper || upper > _length)
            onArraySliceError(lower, upper, _length);
        return _ptr[lower .. upper];
    }

    void swap(ref ManualArray other) @trusted nothrow @nogc
    {
        auto p = _ptr;
        _ptr = other._ptr;
        other._ptr = p;

        auto n = _length;
        _length = other._length;
        other._length = n;

        auto cap = _capacity;
        _capacity = other._capacity;
        other._capacity = cap;
    }

private:
    void ensureAppendCapacity(size_t additional) @trusted nothrow @nogc
    {
        if (additional > size_t.max - _length)
            onOutOfMemoryError();

        const required = _length + additional;
        if (required <= _capacity)
            return;

        size_t next = _capacity == 0 ? 16 : _capacity;
        while (next < required)
        {
            if (next > size_t.max / 2)
            {
                next = required;
                break;
            }
            next *= 2;
        }
        reserve(next);
    }
}

/** Lifecycle state retained by the editable store. */
enum StoreElementState : ubyte
{
    clean,
    created,
    modified,
    deleted,
}

/** Structured store failure category. */
enum StoreError : ubyte
{
    none,
    invalidId,
    duplicateId,
    invalidVersion,
    invalidHandle,
    wrongElementType,
    deletedElement,
    idMismatch,
    unresolvedLocalReference,
    duplicateTagKey,
    emptyTagKey,
}

/** Status returned by fallible store operations. */
struct StoreStatus
{
    StoreError error;
    ElementType type;
    OsmId id;

    @property bool ok() const @safe pure nothrow @nogc
    {
        return error == StoreError.none;
    }
}

/**
 * Stable logical identity for one store element.
 *
 * .init is an invalid handle. A handle remains stable across replacement,
 * deletion/restore and later ID remapping. Whole-store rebuild/compaction may
 * explicitly invalidate handles by changing the store epoch.
 */
struct OsmHandle
{
private:
    ElementType _type;
    uint _slot;
    uint _generation;
    uint _epoch;

public:
    @property ElementType type() const @safe pure nothrow @nogc
    {
        return _type;
    }

    @property bool valid() const @safe pure nothrow @nogc
    {
        return _generation != 0 && _epoch != 0;
    }
}

/** Live and tombstone counts by element type. */
struct StoreCounts
{
    size_t liveNodes;
    size_t liveWays;
    size_t liveRelations;
    size_t nodeSlots;
    size_t waySlots;
    size_t relationSlots;

    @property size_t liveTotal() const @safe pure nothrow @nogc
    {
        return liveNodes + liveWays + liveRelations;
    }
}

/**
 * Logical owned-byte accounting for the compact representation.
 *
 * This intentionally excludes allocator headers and GC bookkeeping; RSS in the
 * city-scale benchmark is the allocator-inclusive measurement.
 */
struct StoreMemoryUsage
{
    size_t elementColumns;
    size_t childPools;
    size_t stringPool;
    size_t primaryIndexes;
    size_t parentIndexes;
    size_t editBaselines;

    @property size_t totalOwnedBytes() const @safe pure nothrow @nogc
    {
        return elementColumns + childPools + stringPool +
               primaryIndexes + parentIndexes + editBaselines;
    }
}

/** Borrowed metadata view backed by the store's current string pool. */
struct StoreMetadataView
{
    bool hasVersion;
    int versionNumber;
    bool hasTimestamp;
    long timestampMilliseconds;
    bool hasChangeset;
    long changesetId;
    bool hasUserId;
    int userId;
    bool hasUsername;
    const(ubyte)[] username;
    bool hasVisibility;
    bool visible;

    @property bool empty() const @safe pure nothrow @nogc
    {
        return !hasVersion && !hasTimestamp && !hasChangeset &&
               !hasUserId && !hasUsername && !hasVisibility;
    }
}

/** One borrowed tag. */
struct StoreTagView
{
    const(ubyte)[] key;
    const(ubyte)[] value;
}

/** Borrowed ordered tag range. Invalidated by structural store mutation. */
struct StoreTagRange
{
private:
    OsmStore _store;
    uint _offset;
    uint _length;
    uint _position;

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _position >= _length;
    }

    @property StoreTagView front() @safe nothrow @nogc
    {
        return _store.tagAt(_offset + _position);
    }

    void popFront() @safe nothrow @nogc
    {
        if (_position < _length)
            ++_position;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return cast(size_t)(_length - _position);
    }
}

/** One ordered Way node reference. */
struct StoreWayNodeView
{
    OsmId id;
    bool hasLocation;
    LocationView location;
}

/** Borrowed ordered Way-node range. Invalidated by structural mutation. */
struct StoreWayNodeRange
{
private:
    OsmStore _store;
    uint _refOffset;
    uint _refLength;
    uint _position;
    uint _locationOffset;
    uint _locationLength;
    uint _locationPosition;

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _position >= _refLength;
    }

    @property StoreWayNodeView front() @safe nothrow @nogc
    {
        StoreWayNodeView result;
        result.id = _store._wayRefIds[_refOffset + _position];

        while (_locationPosition < _locationLength)
        {
            auto entry = _store._wayLocations[
                _locationOffset + _locationPosition];

            if (entry.relativeIndex < _position)
            {
                ++_locationPosition;
                continue;
            }

            if (entry.relativeIndex == _position)
            {
                result.hasLocation = true;
                result.location = LocationView(
                    entry.latitudeNanodegrees,
                    entry.longitudeNanodegrees);
            }
            break;
        }

        return result;
    }

    void popFront() @safe nothrow @nogc
    {
        if (_position >= _refLength)
            return;

        if (_locationPosition < _locationLength)
        {
            auto entry = _store._wayLocations[
                _locationOffset + _locationPosition];
            if (entry.relativeIndex == _position)
                ++_locationPosition;
        }

        ++_position;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return cast(size_t)(_refLength - _position);
    }
}

/** One borrowed ordered Relation member. */
struct StoreRelationMemberView
{
    ElementType type;
    OsmId id;
    const(ubyte)[] role;
}

/** Borrowed ordered Relation-member range. Invalidated by structural mutation. */
struct StoreRelationMemberRange
{
private:
    OsmStore _store;
    uint _offset;
    uint _length;
    uint _position;

public:
    @property bool empty() const @safe pure nothrow @nogc
    {
        return _position >= _length;
    }

    @property StoreRelationMemberView front() @safe nothrow @nogc
    {
        const i = _offset + _position;
        StoreRelationMemberView result;
        result.type = cast(ElementType)_store._relationMemberTypes[i];
        result.id = _store._relationMemberIds[i];
        result.role = _store._strings.get(_store._relationMemberRoles[i]);
        return result;
    }

    void popFront() @safe nothrow @nogc
    {
        if (_position < _length)
            ++_position;
    }

    @property size_t length() const @safe pure nothrow @nogc
    {
        return cast(size_t)(_length - _position);
    }
}

/** Borrowed Node semantic view. Invalidated by structural store mutation. */
struct StoreNodeView
{
    OsmHandle handle;
    OsmId id;
    LocationView location;
    StoreMetadataView metadata;
    StoreTagRange tags;
    StoreElementState state;
}

/** Borrowed Way semantic view. Invalidated by structural store mutation. */
struct StoreWayView
{
    OsmHandle handle;
    OsmId id;
    StoreMetadataView metadata;
    StoreTagRange tags;
    StoreWayNodeRange nodes;
    StoreElementState state;
}

/** Borrowed Relation semantic view. Invalidated by structural store mutation. */
struct StoreRelationView
{
    OsmHandle handle;
    OsmId id;
    StoreMetadataView metadata;
    StoreTagRange tags;
    StoreRelationMemberRange members;
    StoreElementState state;
}

/**
 * Borrowed range of distinct live Ways that reference one Node ID.
 *
 * Duplicate references from the same Way are reported once. The range is
 * invalidated by structural store mutation.
 */
struct StoreParentWayRange
{
private:
    OsmStore _store;
    uint _edge;

    void skipUnavailable() @safe nothrow @nogc
    {
        while (_edge != 0)
        {
            const edge = _store._nodeWayParents.edge(_edge);
            if (edge.active &&
                edge.parentSlot < _store._ways.states.length &&
                _store._ways.states[edge.parentSlot] !=
                    StoreElementState.deleted)
                return;
            _edge = edge.next;
        }
    }

public:
    @property bool empty() @safe nothrow @nogc
    {
        skipUnavailable();
        return _edge == 0;
    }

    @property StoreWayView front() @safe nothrow @nogc
    {
        skipUnavailable();
        assert(_edge != 0);
        const edge = _store._nodeWayParents.edge(_edge);
        return _store.wayViewAt(edge.parentSlot);
    }

    void popFront() @safe nothrow @nogc
    {
        skipUnavailable();
        if (_edge == 0)
            return;
        const edge = _store._nodeWayParents.edge(_edge);
        _edge = edge.next;
        skipUnavailable();
    }
}

/**
 * Borrowed range of distinct live Relations that reference one typed OSM ID.
 *
 * Duplicate members from the same Relation are reported once. The range is
 * invalidated by structural store mutation.
 */
struct StoreParentRelationRange
{
private:
    OsmStore _store;
    ElementType _childType;
    uint _edge;

    void skipUnavailable() @safe nothrow @nogc
    {
        while (_edge != 0)
        {
            const edge = _store.relationParentEdge(_childType, _edge);
            if (edge.active &&
                edge.parentSlot < _store._relations.states.length &&
                _store._relations.states[edge.parentSlot] !=
                    StoreElementState.deleted)
                return;
            _edge = edge.next;
        }
    }

public:
    @property bool empty() @safe nothrow @nogc
    {
        skipUnavailable();
        return _edge == 0;
    }

    @property StoreRelationView front() @safe nothrow @nogc
    {
        skipUnavailable();
        assert(_edge != 0);
        const edge = _store.relationParentEdge(_childType, _edge);
        return _store.relationViewAt(edge.parentSlot);
    }

    void popFront() @safe nothrow @nogc
    {
        skipUnavailable();
        if (_edge == 0)
            return;
        const edge = _store.relationParentEdge(_childType, _edge);
        _edge = edge.next;
        skipUnavailable();
    }
}

/** Deterministic live Node range in slot/insertion order. */
struct StoreNodeRange
{
private:
    OsmStore _store;
    uint _slot;

    void skipDeleted() @safe nothrow @nogc
    {
        while (_slot < _store._nodes.ids.length &&
               _store._nodes.states[_slot] == StoreElementState.deleted)
            ++_slot;
    }

public:
    @property bool empty() @safe nothrow @nogc
    {
        skipDeleted();
        return _slot >= _store._nodes.ids.length;
    }

    @property StoreNodeView front() @safe nothrow @nogc
    {
        skipDeleted();
        return _store.nodeViewAt(_slot);
    }

    void popFront() @safe nothrow @nogc
    {
        if (_slot < _store._nodes.ids.length)
            ++_slot;
        skipDeleted();
    }
}

/** Deterministic live Way range in slot/insertion order. */
struct StoreWayRange
{
private:
    OsmStore _store;
    uint _slot;

    void skipDeleted() @safe nothrow @nogc
    {
        while (_slot < _store._ways.ids.length &&
               _store._ways.states[_slot] == StoreElementState.deleted)
            ++_slot;
    }

public:
    @property bool empty() @safe nothrow @nogc
    {
        skipDeleted();
        return _slot >= _store._ways.ids.length;
    }

    @property StoreWayView front() @safe nothrow @nogc
    {
        skipDeleted();
        return _store.wayViewAt(_slot);
    }

    void popFront() @safe nothrow @nogc
    {
        if (_slot < _store._ways.ids.length)
            ++_slot;
        skipDeleted();
    }
}

/** Deterministic live Relation range in slot/insertion order. */
struct StoreRelationRange
{
private:
    OsmStore _store;
    uint _slot;

    void skipDeleted() @safe nothrow @nogc
    {
        while (_slot < _store._relations.ids.length &&
               _store._relations.states[_slot] == StoreElementState.deleted)
            ++_slot;
    }

public:
    @property bool empty() @safe nothrow @nogc
    {
        skipDeleted();
        return _slot >= _store._relations.ids.length;
    }

    @property StoreRelationView front() @safe nothrow @nogc
    {
        skipDeleted();
        return _store.relationViewAt(_slot);
    }

    void popFront() @safe nothrow @nogc
    {
        if (_slot < _store._relations.ids.length)
            ++_slot;
        skipDeleted();
    }
}

private shared uint nextStoreEpoch;

private struct Span32
{
    uint offset;
    uint length;
}

private struct CompactTag
{
    uint key;
    uint value;
}

private struct SparseWayLocation
{
    uint relativeIndex;
    long latitudeNanodegrees;
    long longitudeNanodegrees;
}

private struct StringEntry
{
    uint offset;
    uint length;
}

private struct StringPool
{
    ManualArray!ubyte bytes;
    ManualArray!StringEntry entries;
    ManualArray!uint buckets;
    size_t count;

    void initialize() @safe nothrow @nogc
    {
        if (entries.length != 0)
            return;
        entries ~= StringEntry(0, 0);
        buckets.length = 16;
        count = 1;
    }

    void prepare(size_t maximumEntries, size_t maximumBytes) @safe nothrow @nogc
    {
        if (entries.length == 0)
            initialize();

        entries.reserve(maximumEntries + 1);
        bytes.reserve(maximumBytes);

        size_t capacity = 16;
        while (capacity * 7 < (maximumEntries + 1) * 10)
            capacity *= 2;

        if (capacity > buckets.length)
        {
            ManualArray!uint replacement;
            replacement.length = capacity;
            buckets.swap(replacement);
            count = entries.length;
        }
    }

    uint intern(scope const(ubyte)[] value) @safe nothrow @nogc
    {
        if (entries.length == 0)
            initialize();

        if (value.length == 0)
            return 0;

        if ((count + 1) * 10 >= buckets.length * 7)
            rehash(buckets.length * 2);

        const hash = hashBytes(value);
        size_t mask = buckets.length - 1;
        size_t pos = cast(size_t)hash & mask;

        for (;;)
        {
            const encoded = buckets[pos];
            if (encoded == 0)
                break;

            const id = encoded - 1;
            if (sameBytes(get(id), value))
                return id;

            pos = (pos + 1) & mask;
        }

        assert(bytes.length <= uint.max);
        assert(value.length <= uint.max);
        assert(bytes.length + value.length <= uint.max);
        assert(entries.length <= uint.max);

        const id = cast(uint)entries.length;
        const offset = cast(uint)bytes.length;
        bytes ~= value;
        entries ~= StringEntry(offset, cast(uint)value.length);
        buckets[pos] = id + 1;
        ++count;
        return id;
    }

    const(ubyte)[] get(uint id) const @safe nothrow @nogc
    {
        assert(id < entries.length);
        const entry = entries[id];
        return bytes[entry.offset .. entry.offset + entry.length];
    }

    void rehash(size_t requested) @safe nothrow @nogc
    {
        size_t capacity = 16;
        while (capacity < requested)
            capacity *= 2;

        ManualArray!uint replacement;
        replacement.length = capacity;

        foreach (uint id; 1 .. cast(uint)entries.length)
        {
            const value = get(id);
            const hash = hashBytes(value);
            size_t mask = replacement.length - 1;
            size_t pos = cast(size_t)hash & mask;
            while (replacement[pos] != 0)
                pos = (pos + 1) & mask;
            replacement[pos] = id + 1;
        }

        buckets.swap(replacement);
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return bytes.length * ubyte.sizeof +
               entries.length * StringEntry.sizeof +
               buckets.length * uint.sizeof;
    }
}

private struct IdIndex
{
    ManualArray!OsmId keys;
    ManualArray!uint values;
    size_t count;
    size_t deleted;

    void initialize() @safe nothrow @nogc
    {
        if (values.length != 0)
            return;
        keys.length = 16;
        values.length = 16;
    }

    void prepare(size_t expectedEntries) @safe nothrow @nogc
    {
        size_t capacity = 16;
        while (capacity * 7 < expectedEntries * 10)
            capacity *= 2;

        ManualArray!OsmId newKeys;
        ManualArray!uint newValues;
        newKeys.length = capacity;
        newValues.length = capacity;
        keys.swap(newKeys);
        values.swap(newValues);
        count = 0;
        deleted = 0;
    }

    bool find(OsmId id, out uint slot) const @safe nothrow @nogc
    {
        slot = 0;
        if (values.length == 0 || id == 0)
            return false;

        size_t mask = values.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;

        for (;;)
        {
            const encoded = values[pos];
            if (encoded == 0)
                return false;

            if (encoded != uint.max && keys[pos] == id)
            {
                slot = encoded - 1;
                return true;
            }

            pos = (pos + 1) & mask;
        }
    }

    bool insert(OsmId id, uint slot) @safe nothrow @nogc
    {
        if (values.length == 0)
            initialize();

        uint existing;
        if (find(id, existing))
            return false;

        if ((count + deleted + 1) * 10 >= values.length * 7)
            rehash(values.length * 2);

        size_t mask = values.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;
        size_t firstDeleted = size_t.max;

        for (;;)
        {
            const encoded = values[pos];
            if (encoded == 0)
            {
                if (firstDeleted != size_t.max)
                    pos = firstDeleted;
                keys[pos] = id;
                values[pos] = slot + 1;
                ++count;
                if (firstDeleted != size_t.max)
                    --deleted;
                return true;
            }

            if (encoded == uint.max && firstDeleted == size_t.max)
                firstDeleted = pos;

            pos = (pos + 1) & mask;
        }
    }

    bool remove(OsmId id) @safe nothrow @nogc
    {
        if (values.length == 0 || id == 0)
            return false;

        size_t mask = values.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;

        for (;;)
        {
            const encoded = values[pos];
            if (encoded == 0)
                return false;

            if (encoded != uint.max && keys[pos] == id)
            {
                values[pos] = uint.max;
                --count;
                ++deleted;
                return true;
            }

            pos = (pos + 1) & mask;
        }
    }

    void rehash(size_t requested) @safe nothrow @nogc
    {
        size_t capacity = 16;
        while (capacity < requested)
            capacity *= 2;

        ManualArray!OsmId newKeys;
        ManualArray!uint newValues;
        newKeys.length = capacity;
        newValues.length = capacity;

        size_t liveCount;
        foreach (i; 0 .. values.length)
        {
            const encoded = values[i];
            if (encoded == 0 || encoded == uint.max)
                continue;

            const id = keys[i];
            size_t mask = newValues.length - 1;
            size_t pos = cast(size_t)hashId(id) & mask;
            while (newValues[pos] != 0)
                pos = (pos + 1) & mask;

            newKeys[pos] = id;
            newValues[pos] = encoded;
            ++liveCount;
        }

        keys.swap(newKeys);
        values.swap(newValues);
        count = liveCount;
        deleted = 0;
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return keys.length * OsmId.sizeof + values.length * uint.sizeof;
    }
}

private struct ParentEdge
{
private:
    enum inactiveMask = 0x8000_0000u;

public:
    /// Parent slot with the high bit reserved as the active-state marker.
    uint parentState;
    /// Encoded next edge index: zero means end, otherwise index + 1.
    uint next;

    @property bool active() const @safe pure nothrow @nogc
    {
        return (parentState & inactiveMask) == 0;
    }

    @property uint parentSlot() const @safe pure nothrow @nogc
    {
        return parentState & ~inactiveMask;
    }

    void deactivate() @safe pure nothrow @nogc
    {
        parentState |= inactiveMask;
    }

    void activate() @safe pure nothrow @nogc
    {
        parentState &= ~inactiveMask;
    }

    static ParentEdge make(
        uint parentSlot,
        uint next,
        bool active = true) @safe pure nothrow @nogc
    {
        assert(parentSlot < inactiveMask);
        ParentEdge result;
        result.parentState = parentSlot | (active ? 0 : inactiveMask);
        result.next = next;
        return result;
    }
}

private struct ParentIndex
{
    ManualArray!OsmId keys;
    ManualArray!uint heads;
    ManualArray!ParentEdge edges;
    size_t keyCount;

    void initialize() @safe nothrow @nogc
    {
        if (heads.length != 0)
            return;
        keys.length = 16;
        heads.length = 16;
    }

    void reserveEdges(size_t expectedEdges) @safe nothrow @nogc
    {
        edges.reserve(expectedEdges);
    }

    uint head(OsmId id) const @safe nothrow @nogc
    {
        if (id == 0 || heads.length == 0)
            return 0;

        size_t mask = heads.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;
        for (;;)
        {
            const key = keys[pos];
            if (key == 0)
                return 0;
            if (key == id)
                return heads[pos];
            pos = (pos + 1) & mask;
        }
    }

    uint insert(
        OsmId id,
        uint parentSlot,
        bool active = true) @safe nothrow @nogc
    {
        assert(id != 0);
        if (heads.length == 0)
            initialize();

        size_t bucket = findBucket(id);
        if (bucket == size_t.max &&
            (keyCount + 1) * 10 >= heads.length * 7)
        {
            rehash(heads.length * 2);
            bucket = findBucket(id);
        }

        if (bucket == size_t.max)
        {
            size_t mask = heads.length - 1;
            bucket = cast(size_t)hashId(id) & mask;
            while (keys[bucket] != 0)
                bucket = (bucket + 1) & mask;
            keys[bucket] = id;
            ++keyCount;
        }
        else
        {
            auto current = heads[bucket];
            while (current != 0)
            {
                const value = edge(current);
                if (value.parentSlot == parentSlot)
                {
                    if (active)
                        edges[current - 1].activate();
                    return current;
                }
                current = value.next;
            }
        }

        assert(edges.length < uint.max);
        edges ~= ParentEdge.make(parentSlot, heads[bucket], active);
        const encoded = cast(uint)edges.length;
        heads[bucket] = encoded;
        return encoded;
    }

    bool deactivate(OsmId id, uint parentSlot) @safe nothrow @nogc
    {
        auto current = head(id);
        while (current != 0)
        {
            const index = cast(size_t)(current - 1);
            if (edges[index].parentSlot == parentSlot &&
                edges[index].active)
            {
                edges[index].deactivate();
                return true;
            }
            current = edges[index].next;
        }
        return false;
    }

    void deactivateEncoded(uint encoded) @safe nothrow @nogc
    {
        if (encoded == 0)
            return;
        const index = cast(size_t)(encoded - 1);
        assert(index < edges.length);
        edges[index].deactivate();
    }

    ParentEdge edge(uint encoded) const @safe nothrow @nogc
    {
        assert(encoded != 0);
        const index = cast(size_t)(encoded - 1);
        assert(index < edges.length);
        return edges[index];
    }

    size_t activeCount(OsmId id) const @safe nothrow @nogc
    {
        size_t result;
        auto current = head(id);
        while (current != 0)
        {
            const value = edge(current);
            if (value.active)
                ++result;
            current = value.next;
        }
        return result;
    }

    void reserveAdditionalEdges(size_t count) @safe nothrow @nogc
    {
        edges.reserve(edges.length + count);
    }

    size_t edgeCount(OsmId id) const @safe nothrow @nogc
    {
        size_t result;
        auto current = head(id);
        while (current != 0)
        {
            ++result;
            current = edge(current).next;
        }
        return result;
    }

    void ensureKey(OsmId id) @safe nothrow @nogc
    {
        assert(id != 0);
        if (heads.length == 0)
            initialize();

        if (findBucket(id) != size_t.max)
            return;

        if ((keyCount + 1) * 10 >= heads.length * 7)
            rehash(heads.length * 2);

        size_t mask = heads.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;
        while (keys[pos] != 0)
            pos = (pos + 1) & mask;
        keys[pos] = id;
        ++keyCount;
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return keys.length * OsmId.sizeof +
               heads.length * uint.sizeof +
               edges.length * ParentEdge.sizeof;
    }

private:
    size_t findBucket(OsmId id) const @safe nothrow @nogc
    {
        if (heads.length == 0)
            return size_t.max;

        size_t mask = heads.length - 1;
        size_t pos = cast(size_t)hashId(id) & mask;
        for (;;)
        {
            const key = keys[pos];
            if (key == 0)
                return size_t.max;
            if (key == id)
                return pos;
            pos = (pos + 1) & mask;
        }
    }

    void rehash(size_t requested) @safe nothrow @nogc
    {
        size_t capacity = 16;
        while (capacity < requested)
            capacity *= 2;

        ManualArray!OsmId newKeys;
        ManualArray!uint newHeads;
        newKeys.length = capacity;
        newHeads.length = capacity;

        foreach (i; 0 .. keys.length)
        {
            const id = keys[i];
            if (id == 0)
                continue;

            size_t mask = capacity - 1;
            size_t pos = cast(size_t)hashId(id) & mask;
            while (newKeys[pos] != 0)
                pos = (pos + 1) & mask;

            newKeys[pos] = id;
            newHeads[pos] = heads[i];
        }

        keys.swap(newKeys);
        heads.swap(newHeads);
    }
}

private struct MetadataColumns
{
    ManualArray!ubyte flags;
    ManualArray!int versions;
    ManualArray!long timestamps;
    ManualArray!long changesets;
    ManualArray!int userIds;
    ManualArray!uint usernames;
    ManualArray!ubyte visible;

    void reserve(size_t count) @safe
    {
        flags.reserve(count);
        versions.reserve(count);
        timestamps.reserve(count);
        changesets.reserve(count);
        userIds.reserve(count);
        usernames.reserve(count);
        visible.reserve(count);
    }

    void append(scope ref const OwnedMetadata value, ref StringPool strings)
        @safe
    {
        ubyte bits;
        if (value.hasVersion) bits |= 1 << 0;
        if (value.hasTimestamp) bits |= 1 << 1;
        if (value.hasChangeset) bits |= 1 << 2;
        if (value.hasUserId) bits |= 1 << 3;
        if (value.hasUsername) bits |= 1 << 4;
        if (value.hasVisibility) bits |= 1 << 5;

        flags ~= bits;
        versions ~= value.versionNumber;
        timestamps ~= value.timestampMilliseconds;
        changesets ~= value.changesetId;
        userIds ~= value.userId;
        usernames ~= value.hasUsername ? strings.intern(value.username) : 0;
        visible ~= value.visible ? 1 : 0;
    }


    void appendBorrowed(Metadata)(Metadata value, ref StringPool strings)
        @safe nothrow @nogc
    {
        ubyte bits;
        if (value.hasVersion) bits |= 1 << 0;
        if (value.hasTimestamp) bits |= 1 << 1;
        if (value.hasChangeset) bits |= 1 << 2;
        if (value.hasUserId) bits |= 1 << 3;
        if (value.hasUsername) bits |= 1 << 4;
        if (value.hasVisibility) bits |= 1 << 5;

        flags ~= bits;
        versions ~= value.versionNumber;
        timestamps ~= value.timestampMilliseconds;
        changesets ~= value.changesetId;
        userIds ~= value.userId;
        usernames ~= value.hasUsername ? strings.intern(value.username) : 0;
        visible ~= value.visible ? 1 : 0;
    }

    void set(uint slot, scope ref const OwnedMetadata value, ref StringPool strings)
        @safe
    {
        ubyte bits;
        if (value.hasVersion) bits |= 1 << 0;
        if (value.hasTimestamp) bits |= 1 << 1;
        if (value.hasChangeset) bits |= 1 << 2;
        if (value.hasUserId) bits |= 1 << 3;
        if (value.hasUsername) bits |= 1 << 4;
        if (value.hasVisibility) bits |= 1 << 5;

        flags[slot] = bits;
        versions[slot] = value.versionNumber;
        timestamps[slot] = value.timestampMilliseconds;
        changesets[slot] = value.changesetId;
        userIds[slot] = value.userId;
        usernames[slot] = value.hasUsername ? strings.intern(value.username) : 0;
        visible[slot] = value.visible ? 1 : 0;
    }

    StoreMetadataView view(uint slot, ref StringPool strings)
        @safe nothrow @nogc
    {
        StoreMetadataView result;
        const bits = flags[slot];
        result.hasVersion = (bits & (1 << 0)) != 0;
        result.versionNumber = versions[slot];
        result.hasTimestamp = (bits & (1 << 1)) != 0;
        result.timestampMilliseconds = timestamps[slot];
        result.hasChangeset = (bits & (1 << 2)) != 0;
        result.changesetId = changesets[slot];
        result.hasUserId = (bits & (1 << 3)) != 0;
        result.userId = userIds[slot];
        result.hasUsername = (bits & (1 << 4)) != 0;
        if (result.hasUsername)
            result.username = strings.get(usernames[slot]);
        result.hasVisibility = (bits & (1 << 5)) != 0;
        result.visible = visible[slot] != 0;
        return result;
    }

    OwnedMetadata owned(uint slot, ref StringPool strings) @safe
    {
        OwnedMetadata result;
        const bits = flags[slot];
        result.hasVersion = (bits & (1 << 0)) != 0;
        result.versionNumber = versions[slot];
        result.hasTimestamp = (bits & (1 << 1)) != 0;
        result.timestampMilliseconds = timestamps[slot];
        result.hasChangeset = (bits & (1 << 2)) != 0;
        result.changesetId = changesets[slot];
        result.hasUserId = (bits & (1 << 3)) != 0;
        result.userId = userIds[slot];
        result.hasUsername = (bits & (1 << 4)) != 0;
        if (result.hasUsername)
            result.username = strings.get(usernames[slot]).idup;
        result.hasVisibility = (bits & (1 << 5)) != 0;
        result.visible = visible[slot] != 0;
        return result;
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return flags.length * ubyte.sizeof +
               versions.length * int.sizeof +
               timestamps.length * long.sizeof +
               changesets.length * long.sizeof +
               userIds.length * int.sizeof +
               usernames.length * uint.sizeof +
               visible.length * ubyte.sizeof;
    }
}

private struct CommonColumns
{
    ManualArray!OsmId ids;
    ManualArray!StoreElementState states;
    ManualArray!StoreElementState deletedFrom;
    ManualArray!uint generations;
    ManualArray!Span32 tags;
    MetadataColumns metadata;

    void reserve(size_t count) @safe
    {
        ids.reserve(count);
        states.reserve(count);
        deletedFrom.reserve(count);
        generations.reserve(count);
        tags.reserve(count);
        metadata.reserve(count);
    }

    void append(
        OsmId id,
        StoreElementState state,
        Span32 tagSpan,
        scope ref const OwnedMetadata metadataValue,
        ref StringPool strings) @safe
    {
        ids ~= id;
        states ~= state;
        deletedFrom ~= state;
        generations ~= 1;
        tags ~= tagSpan;
        metadata.append(metadataValue, strings);
    }


    void appendBorrowed(Metadata)(
        OsmId id,
        StoreElementState state,
        Span32 tagSpan,
        Metadata metadataValue,
        ref StringPool strings) @safe nothrow @nogc
    {
        ids ~= id;
        states ~= state;
        deletedFrom ~= state;
        generations ~= 1;
        tags ~= tagSpan;
        metadata.appendBorrowed(metadataValue, strings);
    }

    @property size_t logicalBytes() const @safe pure nothrow @nogc
    {
        return ids.length * OsmId.sizeof +
               states.length * StoreElementState.sizeof +
               deletedFrom.length * StoreElementState.sizeof +
               generations.length * uint.sizeof +
               tags.length * Span32.sizeof +
               metadata.logicalBytes;
    }
}

private ulong hashBytes(scope const(ubyte)[] value)
    @safe pure nothrow @nogc
{
    ulong hash = 1469598103934665603UL;
    foreach (b; value)
    {
        hash ^= b;
        hash *= 1099511628211UL;
    }
    return hash;
}

private ulong hashId(OsmId id) @safe pure nothrow @nogc
{
    ulong x = cast(ulong)id;
    x ^= x >> 30;
    x *= 0xbf58476d1ce4e5b9UL;
    x ^= x >> 27;
    x *= 0x94d049bb133111ebUL;
    x ^= x >> 31;
    return x;
}

private bool sameBytes(
    scope const(ubyte)[] a,
    scope const(ubyte)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, value; a)
    {
        if (value != b[i])
            return false;
    }
    return true;
}

private struct BuildPlan
{
    size_t nodes;
    size_t ways;
    size_t relations;
    size_t tags;
    size_t wayRefs;
    size_t wayLocations;
    size_t relationMembers;
    size_t relationNodeMembers;
    size_t relationWayMembers;
    size_t relationRelationMembers;
    size_t stringOccurrences;
    size_t stringBytes;
}

private BuildPlan makeBuildPlan(scope ref const OwnedDataset data)
    @safe pure nothrow @nogc
{
    BuildPlan plan;
    plan.nodes = data.nodes.length;
    plan.ways = data.ways.length;
    plan.relations = data.relations.length;

    foreach (ref const node; data.nodes)
    {
        plan.tags += node.tags.length;
        plan.stringOccurrences += node.tags.length * 2;
        foreach (ref const tag; node.tags)
            plan.stringBytes += tag.key.length + tag.value.length;
        if (node.metadata.hasUsername)
        {
            ++plan.stringOccurrences;
            plan.stringBytes += node.metadata.username.length;
        }
    }

    foreach (ref const way; data.ways)
    {
        plan.tags += way.tags.length;
        plan.wayRefs += way.nodes.length;
        plan.stringOccurrences += way.tags.length * 2;
        foreach (ref const tag; way.tags)
            plan.stringBytes += tag.key.length + tag.value.length;
        foreach (ref const node; way.nodes)
            if (node.hasLocation)
                ++plan.wayLocations;
        if (way.metadata.hasUsername)
        {
            ++plan.stringOccurrences;
            plan.stringBytes += way.metadata.username.length;
        }
    }

    foreach (ref const relation; data.relations)
    {
        plan.tags += relation.tags.length;
        plan.relationMembers += relation.members.length;
        plan.stringOccurrences +=
            relation.tags.length * 2 + relation.members.length;
        foreach (ref const tag; relation.tags)
            plan.stringBytes += tag.key.length + tag.value.length;
        foreach (ref const member; relation.members)
        {
            plan.stringBytes += member.role.length;
            final switch (member.type)
            {
                case ElementType.node:
                    ++plan.relationNodeMembers;
                    break;
                case ElementType.way:
                    ++plan.relationWayMembers;
                    break;
                case ElementType.relation:
                    ++plan.relationRelationMembers;
                    break;
            }
        }
        if (relation.metadata.hasUsername)
        {
            ++plan.stringOccurrences;
            plan.stringBytes += relation.metadata.username.length;
        }
    }

    return plan;
}

/**
 * Editable, process-local OSM semantic store.
 *
 * Fixed element fields use columnar storage. Tags, Way references and Relation
 * members use compact append-only pools. Strings are interned into one byte
 * pool. The implementation owns all bytes inserted into it.
 *
 * Mutations are single-writer and externally synchronized. Borrowed views and
 * ranges are invalidated by structural mutation. .init is not constructible;
 * use new OsmStore.
 */
final class OsmStore
{
private:
    uint _epoch;

    StringPool _strings;

    CommonColumns _nodes;
    ManualArray!long _nodeLatitudes;
    ManualArray!long _nodeLongitudes;

    CommonColumns _ways;
    ManualArray!Span32 _wayRefs;
    ManualArray!Span32 _wayLocationSpans;

    CommonColumns _relations;
    ManualArray!Span32 _relationMembers;

    ManualArray!CompactTag _tags;
    ManualArray!OsmId _wayRefIds;
    ManualArray!SparseWayLocation _wayLocations;
    ManualArray!OsmId _relationMemberIds;
    ManualArray!uint _relationMemberRoles;
    ManualArray!ubyte _relationMemberTypes;

    IdIndex _nodeIndex;
    IdIndex _wayIndex;
    IdIndex _relationIndex;

    ParentIndex _nodeWayParents;
    ParentIndex _nodeRelationParents;
    ParentIndex _wayRelationParents;
    ParentIndex _relationRelationParents;

    size_t _liveNodes;
    size_t _liveWays;
    size_t _liveRelations;

    OwnedNode[uint] _nodeBaselines;
    OwnedWay[uint] _wayBaselines;
    OwnedRelation[uint] _relationBaselines;

public:
    this() @safe
    {
        _epoch = atomicOp!"+="(nextStoreEpoch, 1);
        if (_epoch == 0)
            _epoch = atomicOp!"+="(nextStoreEpoch, 1);

        _strings.initialize();
        _nodeIndex.initialize();
        _wayIndex.initialize();
        _relationIndex.initialize();
        _nodeWayParents.initialize();
        _nodeRelationParents.initialize();
        _wayRelationParents.initialize();
        _relationRelationParents.initialize();
    }

    /** Insert one validated Node, copying all durable bytes into the store. */
    bool add(
        scope ref const OwnedNode value,
        out OsmHandle handle,
        out StoreStatus status) @safe
    {
        handle = OsmHandle.init;
        status = StoreStatus.init;
        status.type = ElementType.node;
        status.id = value.id;

        if (!preflightIdAndTags(ElementType.node, value.id, value.tags, status))
            return false;

        const tagSpan = appendTags(value.tags);
        const slot = cast(uint)_nodes.ids.length;
        const lifecycle = value.id < 0 ?
            StoreElementState.created : StoreElementState.clean;

        _nodes.append(value.id, lifecycle, tagSpan, value.metadata, _strings);
        _nodeLatitudes ~= value.location.latitudeNanodegrees;
        _nodeLongitudes ~= value.location.longitudeNanodegrees;
        const inserted = _nodeIndex.insert(value.id, slot);
        assert(inserted);
        ++_liveNodes;

        handle = makeHandle(ElementType.node, slot, _nodes.generations[slot]);
        return true;
    }

    /** Insert one validated Way, preserving ordered references and locations. */
    bool add(
        scope ref const OwnedWay value,
        out OsmHandle handle,
        out StoreStatus status) @safe
    {
        handle = OsmHandle.init;
        status = StoreStatus.init;
        status.type = ElementType.way;
        status.id = value.id;

        if (!preflightIdAndTags(ElementType.way, value.id, value.tags, status))
            return false;
        if (!preflightWayReferences(value.nodes, status))
            return false;

        const tagSpan = appendTags(value.tags);
        const slot = cast(uint)_ways.ids.length;
        const refSpan = appendWayNodes(value.nodes, slot);
        const locationSpan = lastWayLocationSpan;
        const lifecycle = value.id < 0 ?
            StoreElementState.created : StoreElementState.clean;

        _ways.append(value.id, lifecycle, tagSpan, value.metadata, _strings);
        _wayRefs ~= refSpan;
        _wayLocationSpans ~= locationSpan;
        const inserted = _wayIndex.insert(value.id, slot);
        assert(inserted);
        ++_liveWays;

        handle = makeHandle(ElementType.way, slot, _ways.generations[slot]);
        return true;
    }

    /** Insert one validated Relation, preserving member order and roles. */
    bool add(
        scope ref const OwnedRelation value,
        out OsmHandle handle,
        out StoreStatus status) @safe
    {
        handle = OsmHandle.init;
        status = StoreStatus.init;
        status.type = ElementType.relation;
        status.id = value.id;

        if (!preflightIdAndTags(
                ElementType.relation, value.id, value.tags, status))
            return false;
        if (!preflightRelationMembers(value.members, status))
            return false;

        const tagSpan = appendTags(value.tags);
        const slot = cast(uint)_relations.ids.length;
        const memberSpan = appendRelationMembers(value.members, slot);
        const lifecycle = value.id < 0 ?
            StoreElementState.created : StoreElementState.clean;

        _relations.append(
            value.id, lifecycle, tagSpan, value.metadata, _strings);
        _relationMembers ~= memberSpan;
        const inserted = _relationIndex.insert(value.id, slot);
        assert(inserted);
        ++_liveRelations;

        handle = makeHandle(
            ElementType.relation, slot, _relations.generations[slot]);
        return true;
    }


    /**
     * Package-internal ingestion from an already validated borrowed Node view.
     *
     * The template is format-neutral: only semantic properties are consumed.
     * It exists to qualify the #62 representation without exposing a codec-
     * specific construction API; #64 owns production direct PBF construction.
     */
    package(osm) bool addBorrowedNode(Node)(
        scope ref Node value,
        out StoreStatus status) @safe nothrow @nogc
    {
        status = StoreStatus.init;
        status.type = ElementType.node;
        status.id = value.id;

        if (!preflightBorrowedIdentity(ElementType.node, value.id, status))
            return false;

        auto sourceTags = value.tags;
        if (!preflightBorrowedTags(sourceTags, status))
            return false;

        const tagSpan = appendBorrowedTags(value.tags);
        const slot = cast(uint)_nodes.ids.length;
        auto metadata = value.metadata;

        _nodes.appendBorrowed(
            value.id,
            StoreElementState.clean,
            tagSpan,
            metadata,
            _strings);
        const location = value.location;
        _nodeLatitudes ~= location.latitudeNanodegrees;
        _nodeLongitudes ~= location.longitudeNanodegrees;

        if (!_nodeIndex.insert(value.id, slot))
        {
            status.error = StoreError.duplicateId;
            return false;
        }

        ++_liveNodes;
        return true;
    }

    /** Package-internal ingestion from an already validated borrowed Way view. */
    package(osm) bool addBorrowedWay(Way)(
        scope ref Way value,
        out StoreStatus status) @safe nothrow @nogc
    {
        status = StoreStatus.init;
        status.type = ElementType.way;
        status.id = value.id;

        if (!preflightBorrowedIdentity(ElementType.way, value.id, status))
            return false;

        auto sourceTags = value.tags;
        if (!preflightBorrowedTags(sourceTags, status))
            return false;

        auto sourceNodes = value.nodes;
        if (!preflightBorrowedWayNodes(sourceNodes, status))
            return false;

        const tagSpan = appendBorrowedTags(value.tags);
        const slot = cast(uint)_ways.ids.length;
        const refSpan = appendBorrowedWayNodes(value.nodes, slot);
        const locationSpan = lastWayLocationSpan;
        auto metadata = value.metadata;

        _ways.appendBorrowed(
            value.id,
            StoreElementState.clean,
            tagSpan,
            metadata,
            _strings);
        _wayRefs ~= refSpan;
        _wayLocationSpans ~= locationSpan;

        if (!_wayIndex.insert(value.id, slot))
        {
            status.error = StoreError.duplicateId;
            return false;
        }

        ++_liveWays;
        return true;
    }

    /**
     * Package-internal ingestion from an already validated borrowed Relation
     * view.
     */
    package(osm) bool addBorrowedRelation(Relation)(
        scope ref Relation value,
        out StoreStatus status) @safe nothrow @nogc
    {
        status = StoreStatus.init;
        status.type = ElementType.relation;
        status.id = value.id;

        if (!preflightBorrowedIdentity(
                ElementType.relation, value.id, status))
            return false;

        auto sourceTags = value.tags;
        if (!preflightBorrowedTags(sourceTags, status))
            return false;

        auto sourceMembers = value.members;
        if (!preflightBorrowedRelationMembers(sourceMembers, status))
            return false;

        const tagSpan = appendBorrowedTags(value.tags);
        const slot = cast(uint)_relations.ids.length;
        const memberSpan =
            appendBorrowedRelationMembers(value.members, slot);
        auto metadata = value.metadata;

        _relations.appendBorrowed(
            value.id,
            StoreElementState.clean,
            tagSpan,
            metadata,
            _strings);
        _relationMembers ~= memberSpan;

        if (!_relationIndex.insert(value.id, slot))
        {
            status.error = StoreError.duplicateId;
            return false;
        }

        ++_liveRelations;
        return true;
    }

    /**
     * Build a complete store transactionally from an owned semantic dataset.
     *
     * On failure store is null and no partially-built result escapes.
     */
    static bool build(
        scope ref const OwnedDataset data,
        out OsmStore store,
        out StoreStatus status) @safe
    {
        store = null;
        status = StoreStatus.init;

        auto candidate = new OsmStore();
        const plan = makeBuildPlan(data);
        candidate.prepareForBuild(plan);

        OsmHandle ignored;

        foreach (ref const value; data.nodes)
            if (!candidate.add(value, ignored, status))
                return false;
        foreach (ref const value; data.ways)
            if (!candidate.add(value, ignored, status))
                return false;
        foreach (ref const value; data.relations)
            if (!candidate.add(value, ignored, status))
                return false;

        store = candidate;
        return true;
    }

    /** Find a live element by typed OSM ID in expected O(1) time. */
    bool find(ElementType type, OsmId id, out OsmHandle handle)
        @safe nothrow @nogc
    {
        handle = OsmHandle.init;
        uint slot;

        final switch (type)
        {
            case ElementType.node:
                if (!_nodeIndex.find(id, slot))
                    return false;
                handle = makeHandle(type, slot, _nodes.generations[slot]);
                return true;
            case ElementType.way:
                if (!_wayIndex.find(id, slot))
                    return false;
                handle = makeHandle(type, slot, _ways.generations[slot]);
                return true;
            case ElementType.relation:
                if (!_relationIndex.find(id, slot))
                    return false;
                handle = makeHandle(type, slot, _relations.generations[slot]);
                return true;
        }
    }

    /** Return lifecycle state for a valid handle, including tombstones. */
    bool state(
        OsmHandle handle,
        out StoreElementState value,
        out StoreStatus status) @safe nothrow @nogc
    {
        value = StoreElementState.init;
        status = StoreStatus.init;
        if (!validateHandle(handle, status))
            return false;

        value = stateAt(handle);
        return true;
    }

    /** Borrow a Node semantic view. */
    bool node(
        OsmHandle handle,
        out StoreNodeView value,
        out StoreStatus status) @safe nothrow @nogc
    {
        value = StoreNodeView.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.node, status))
            return false;
        value = nodeViewAt(handle._slot);
        return true;
    }

    /** Borrow a Way semantic view. */
    bool way(
        OsmHandle handle,
        out StoreWayView value,
        out StoreStatus status) @safe nothrow @nogc
    {
        value = StoreWayView.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.way, status))
            return false;
        value = wayViewAt(handle._slot);
        return true;
    }

    /** Borrow a Relation semantic view. */
    bool relation(
        OsmHandle handle,
        out StoreRelationView value,
        out StoreStatus status) @safe nothrow @nogc
    {
        value = StoreRelationView.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.relation, status))
            return false;
        value = relationViewAt(handle._slot);
        return true;
    }

    /** Copy one Node into the ordinary owned semantic model. */
    bool copyNode(
        OsmHandle handle,
        out OwnedNode value,
        out StoreStatus status) @safe
    {
        value = OwnedNode.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.node, status))
            return false;
        value = copyNodeAt(handle._slot);
        return true;
    }

    /** Copy one Way into the ordinary owned semantic model. */
    bool copyWay(
        OsmHandle handle,
        out OwnedWay value,
        out StoreStatus status) @safe
    {
        value = OwnedWay.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.way, status))
            return false;
        value = copyWayAt(handle._slot);
        return true;
    }

    /** Copy one Relation into the ordinary owned semantic model. */
    bool copyRelation(
        OsmHandle handle,
        out OwnedRelation value,
        out StoreStatus status) @safe
    {
        value = OwnedRelation.init;
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.relation, status))
            return false;
        value = copyRelationAt(handle._slot);
        return true;
    }

    /** Replace complete Node content without changing its handle or ID. */
    bool replace(
        OsmHandle handle,
        scope ref const OwnedNode value,
        out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.node, status))
            return false;

        status.type = ElementType.node;
        status.id = value.id;
        if (value.id != _nodes.ids[handle._slot])
        {
            status.error = StoreError.idMismatch;
            return false;
        }
        if (!preflightTags(value.tags, status))
            return false;

        captureNodeBaseline(handle._slot);
        _nodes.tags[handle._slot] = appendTags(value.tags);
        _nodes.metadata.set(handle._slot, value.metadata, _strings);
        _nodeLatitudes[handle._slot] = value.location.latitudeNanodegrees;
        _nodeLongitudes[handle._slot] = value.location.longitudeNanodegrees;
        markModified(_nodes, handle._slot);
        return true;
    }

    /** Replace complete Way content without changing its handle or ID. */
    bool replace(
        OsmHandle handle,
        scope ref const OwnedWay value,
        out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.way, status))
            return false;

        status.type = ElementType.way;
        status.id = value.id;
        if (value.id != _ways.ids[handle._slot])
        {
            status.error = StoreError.idMismatch;
            return false;
        }
        if (!preflightTags(value.tags, status) ||
            !preflightWayReferences(value.nodes, status))
            return false;

        captureWayBaseline(handle._slot);
        const oldRefs = _wayRefs[handle._slot];
        const newTags = appendTags(value.tags);
        _ways.metadata.set(handle._slot, value.metadata, _strings);

        // Disable the old current contributions before creating the new ones.
        // Otherwise a shared old/new child ID would reactivate the existing
        // parent edge and then be disabled again by the old-span cleanup.
        deactivateWayParents(oldRefs, handle._slot);
        const newRefs = appendWayNodes(value.nodes, handle._slot);
        const newLocations = lastWayLocationSpan;

        _ways.tags[handle._slot] = newTags;
        _wayRefs[handle._slot] = newRefs;
        _wayLocationSpans[handle._slot] = newLocations;
        markModified(_ways, handle._slot);
        return true;
    }

    /** Replace complete Relation content without changing its handle or ID. */
    bool replace(
        OsmHandle handle,
        scope ref const OwnedRelation value,
        out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, ElementType.relation, status))
            return false;

        status.type = ElementType.relation;
        status.id = value.id;
        if (value.id != _relations.ids[handle._slot])
        {
            status.error = StoreError.idMismatch;
            return false;
        }
        if (!preflightTags(value.tags, status) ||
            !preflightRelationMembers(value.members, status))
            return false;

        captureRelationBaseline(handle._slot);
        const oldMembers = _relationMembers[handle._slot];
        const newTags = appendTags(value.tags);
        _relations.metadata.set(handle._slot, value.metadata, _strings);

        deactivateRelationParents(oldMembers, handle._slot);
        const newMembers =
            appendRelationMembers(value.members, handle._slot);

        _relations.tags[handle._slot] = newTags;
        _relationMembers[handle._slot] = newMembers;
        markModified(_relations, handle._slot);
        return true;
    }

    /** Tombstone an existing live element while retaining stable handle state. */
    bool remove(OsmHandle handle, out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateHandle(handle, status))
            return false;

        if (stateAt(handle) == StoreElementState.deleted)
        {
            status.error = StoreError.deletedElement;
            status.type = handle.type;
            status.id = idAt(handle);
            return false;
        }

        final switch (handle.type)
        {
            case ElementType.node:
                captureNodeBaseline(handle._slot);
                _nodes.deletedFrom[handle._slot] = _nodes.states[handle._slot];
                _nodes.states[handle._slot] = StoreElementState.deleted;
                const removed = _nodeIndex.remove(_nodes.ids[handle._slot]);
                assert(removed);
                --_liveNodes;
                break;
            case ElementType.way:
                captureWayBaseline(handle._slot);
                deactivateWayParents(_wayRefs[handle._slot], handle._slot);
                _ways.deletedFrom[handle._slot] = _ways.states[handle._slot];
                _ways.states[handle._slot] = StoreElementState.deleted;
                const removed = _wayIndex.remove(_ways.ids[handle._slot]);
                assert(removed);
                --_liveWays;
                break;
            case ElementType.relation:
                captureRelationBaseline(handle._slot);
                deactivateRelationParents(
                    _relationMembers[handle._slot],
                    handle._slot);
                _relations.deletedFrom[handle._slot] =
                    _relations.states[handle._slot];
                _relations.states[handle._slot] = StoreElementState.deleted;
                const removed =
                    _relationIndex.remove(_relations.ids[handle._slot]);
                assert(removed);
                --_liveRelations;
                break;
        }

        return true;
    }

    /** Restore a tombstoned element without changing its handle. */
    bool restore(OsmHandle handle, out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateHandle(handle, status))
            return false;

        if (stateAt(handle) != StoreElementState.deleted)
            return true;

        final switch (handle.type)
        {
            case ElementType.node:
                if (!_nodeIndex.insert(_nodes.ids[handle._slot], handle._slot))
                {
                    status.error = StoreError.duplicateId;
                    status.type = handle.type;
                    status.id = _nodes.ids[handle._slot];
                    return false;
                }
                _nodes.states[handle._slot] =
                    _nodes.deletedFrom[handle._slot];
                if (_nodes.states[handle._slot] == StoreElementState.clean)
                    _nodeBaselines.remove(handle._slot);
                ++_liveNodes;
                break;
            case ElementType.way:
                if (!_wayIndex.insert(_ways.ids[handle._slot], handle._slot))
                {
                    status.error = StoreError.duplicateId;
                    status.type = handle.type;
                    status.id = _ways.ids[handle._slot];
                    return false;
                }
                reactivateWayParents(
                    _wayRefs[handle._slot], handle._slot);
                _ways.states[handle._slot] =
                    _ways.deletedFrom[handle._slot];
                if (_ways.states[handle._slot] == StoreElementState.clean)
                    _wayBaselines.remove(handle._slot);
                ++_liveWays;
                break;
            case ElementType.relation:
                if (!_relationIndex.insert(
                        _relations.ids[handle._slot], handle._slot))
                {
                    status.error = StoreError.duplicateId;
                    status.type = handle.type;
                    status.id = _relations.ids[handle._slot];
                    return false;
                }
                reactivateRelationParents(
                    _relationMembers[handle._slot], handle._slot);
                _relations.states[handle._slot] =
                    _relations.deletedFrom[handle._slot];
                if (_relations.states[handle._slot] == StoreElementState.clean)
                    _relationBaselines.remove(handle._slot);
                ++_liveRelations;
                break;
        }

        return true;
    }

    /**
     * Revert one edited loaded element to its lazy baseline.
     *
     * Reverting a still-local created element cancels it by tombstoning it.
     */
    bool revert(OsmHandle handle, out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateHandle(handle, status))
            return false;

        if (stateAt(handle) == StoreElementState.clean)
            return true;

        if (stateAt(handle) == StoreElementState.created)
            return remove(handle, status);

        if (stateAt(handle) == StoreElementState.deleted)
        {
            final switch (handle.type)
            {
                case ElementType.node:
                    if (_nodes.deletedFrom[handle._slot] ==
                        StoreElementState.created)
                        return true;
                    break;
                case ElementType.way:
                    if (_ways.deletedFrom[handle._slot] ==
                        StoreElementState.created)
                        return true;
                    break;
                case ElementType.relation:
                    if (_relations.deletedFrom[handle._slot] ==
                        StoreElementState.created)
                        return true;
                    break;
            }

            if (!restore(handle, status))
                return false;
        }

        final switch (handle.type)
        {
            case ElementType.node:
                if (auto baseline = handle._slot in _nodeBaselines)
                {
                    const saved = baseline.deepCopy();
                    if (!replace(handle, saved, status))
                        return false;
                    _nodes.states[handle._slot] = StoreElementState.clean;
                    _nodeBaselines.remove(handle._slot);
                }
                break;

            case ElementType.way:
                if (auto baseline = handle._slot in _wayBaselines)
                {
                    const saved = baseline.deepCopy();
                    if (!replace(handle, saved, status))
                        return false;
                    _ways.states[handle._slot] = StoreElementState.clean;
                    _wayBaselines.remove(handle._slot);
                }
                break;

            case ElementType.relation:
                if (auto baseline = handle._slot in _relationBaselines)
                {
                    const saved = baseline.deepCopy();
                    if (!replace(handle, saved, status))
                        return false;
                    _relations.states[handle._slot] = StoreElementState.clean;
                    _relationBaselines.remove(handle._slot);
                }
                break;
        }

        return true;
    }

    /**
     * Return distinct live Ways that currently reference nodeId.
     *
     * The referenced Node itself need not be present; partial extracts may
     * therefore still expose parents for an unresolved positive ID.
     */
    StoreParentWayRange parentWays(OsmId nodeId) @safe nothrow @nogc
    {
        StoreParentWayRange result;
        result._store = this;
        result._edge = _nodeWayParents.head(nodeId);
        result.skipUnavailable();
        return result;
    }

    /**
     * Return distinct live Relations that reference one typed OSM identity.
     *
     * The referenced child itself need not be present. Element type is part of
     * the identity, so equal numeric Node/Way/Relation IDs stay independent.
     */
    StoreParentRelationRange parentRelations(
        ElementType type,
        OsmId id) @safe nothrow @nogc
    {
        StoreParentRelationRange result;
        result._store = this;
        result._childType = type;
        result._edge = relationParentHead(type, id);
        result.skipUnavailable();
        return result;
    }

    /**
     * Apply an authoritative server ID/version to one local element.
     *
     * The element must currently have a negative local ID. newId must be
     * positive and unused in the same element namespace; newVersion must be
     * positive. All current Way/Relation references, including references held
     * by tombstoned parents, are rewritten coherently. Reverse indexes and the
     * primary index are updated in the same single-writer mutation. The
     * element handle remains stable.
     *
     * On a reported validation failure no visible element/reference/index
     * state changes.
     */
    bool remapId(
        OsmHandle handle,
        OsmId newId,
        int newVersion,
        out StoreStatus status) @safe
    {
        status = StoreStatus.init;
        if (!validateLiveHandle(handle, handle.type, status))
            return false;

        const oldId = idAt(handle);
        status.type = handle.type;
        status.id = oldId;

        if (oldId >= 0 || newId <= 0)
        {
            status.error = StoreError.invalidId;
            return false;
        }

        if (newVersion <= 0)
        {
            status.error = StoreError.invalidVersion;
            return false;
        }

        OsmHandle duplicate;
        if (find(handle.type, newId, duplicate))
        {
            status.error = StoreError.duplicateId;
            status.id = newId;
            return false;
        }

        // Reserve/establish all reverse-index destination state before the
        // first visible semantic rewrite. These operations can allocate but do
        // not expose a parent until an edge is inserted below.
        final switch (handle.type)
        {
            case ElementType.node:
                prepareParentMove(_nodeWayParents, oldId, newId);
                prepareParentMove(_nodeRelationParents, oldId, newId);
                break;
            case ElementType.way:
                prepareParentMove(_wayRelationParents, oldId, newId);
                break;
            case ElementType.relation:
                prepareParentMove(_relationRelationParents, oldId, newId);
                break;
        }

        // The new primary key is also installed before reference mutation.
        // Duplicate rejection above makes this expected to succeed.
        bool inserted;
        final switch (handle.type)
        {
            case ElementType.node:
                inserted = _nodeIndex.insert(newId, handle._slot);
                break;
            case ElementType.way:
                inserted = _wayIndex.insert(newId, handle._slot);
                break;
            case ElementType.relation:
                inserted = _relationIndex.insert(newId, handle._slot);
                break;
        }
        assert(inserted);

        final switch (handle.type)
        {
            case ElementType.node:
                moveWayParentKey(oldId, newId);
                moveRelationParentKey(
                    ElementType.node, oldId, newId);
                _nodes.ids[handle._slot] = newId;
                setAuthoritativeVersion(_nodes, handle._slot, newVersion);
                _nodes.states[handle._slot] = StoreElementState.clean;
                const removed = _nodeIndex.remove(oldId);
                assert(removed);
                break;

            case ElementType.way:
                moveRelationParentKey(
                    ElementType.way, oldId, newId);
                _ways.ids[handle._slot] = newId;
                setAuthoritativeVersion(_ways, handle._slot, newVersion);
                _ways.states[handle._slot] = StoreElementState.clean;
                const removed = _wayIndex.remove(oldId);
                assert(removed);
                break;

            case ElementType.relation:
                moveRelationParentKey(
                    ElementType.relation, oldId, newId);
                _relations.ids[handle._slot] = newId;
                setAuthoritativeVersion(
                    _relations, handle._slot, newVersion);
                _relations.states[handle._slot] = StoreElementState.clean;
                const removed = _relationIndex.remove(oldId);
                assert(removed);
                break;
        }

        status.id = newId;
        return true;
    }

    /** Deterministic live Node iteration. */
    @property StoreNodeRange nodes() @safe nothrow @nogc
    {
        StoreNodeRange result;
        result._store = this;
        result._slot = 0;
        result.skipDeleted();
        return result;
    }

    /** Deterministic live Way iteration. */
    @property StoreWayRange ways() @safe nothrow @nogc
    {
        StoreWayRange result;
        result._store = this;
        result._slot = 0;
        result.skipDeleted();
        return result;
    }

    /** Deterministic live Relation iteration. */
    @property StoreRelationRange relations() @safe nothrow @nogc
    {
        StoreRelationRange result;
        result._store = this;
        result._slot = 0;
        result.skipDeleted();
        return result;
    }

    @property StoreCounts counts() const @safe pure nothrow @nogc
    {
        StoreCounts result;
        result.liveNodes = _liveNodes;
        result.liveWays = _liveWays;
        result.liveRelations = _liveRelations;
        result.nodeSlots = _nodes.ids.length;
        result.waySlots = _ways.ids.length;
        result.relationSlots = _relations.ids.length;
        return result;
    }

    /** Logical representation bytes; allocator-inclusive RSS is benchmarked separately. */
    @property StoreMemoryUsage memoryUsage() @safe
    {
        StoreMemoryUsage result;

        result.elementColumns =
            _nodes.logicalBytes +
            _nodeLatitudes.length * long.sizeof +
            _nodeLongitudes.length * long.sizeof +
            _ways.logicalBytes +
            _wayRefs.length * Span32.sizeof +
            _wayLocationSpans.length * Span32.sizeof +
            _relations.logicalBytes +
            _relationMembers.length * Span32.sizeof;

        result.childPools =
            _tags.length * CompactTag.sizeof +
            _wayRefIds.length * OsmId.sizeof +
            _wayLocations.length * SparseWayLocation.sizeof +
            _relationMemberIds.length * OsmId.sizeof +
            _relationMemberRoles.length * uint.sizeof +
            _relationMemberTypes.length * ubyte.sizeof;

        result.stringPool = _strings.logicalBytes;

        result.primaryIndexes =
            _nodeIndex.logicalBytes +
            _wayIndex.logicalBytes +
            _relationIndex.logicalBytes;

        result.parentIndexes =
            _nodeWayParents.logicalBytes +
            _nodeRelationParents.logicalBytes +
            _wayRelationParents.logicalBytes +
            _relationRelationParents.logicalBytes;

        foreach (slot, ref value; _nodeBaselines)
            result.editBaselines += ownedNodeBytes(value);
        foreach (slot, ref value; _wayBaselines)
            result.editBaselines += ownedWayBytes(value);
        foreach (slot, ref value; _relationBaselines)
            result.editBaselines += ownedRelationBytes(value);

        return result;
    }

private:
    void prepareForBuild(scope ref const BuildPlan plan) @safe
    {
        _strings.prepare(plan.stringOccurrences, plan.stringBytes);

        _nodes.reserve(plan.nodes);
        _nodeLatitudes.reserve(plan.nodes);
        _nodeLongitudes.reserve(plan.nodes);

        _ways.reserve(plan.ways);
        _wayRefs.reserve(plan.ways);
        _wayLocationSpans.reserve(plan.ways);

        _relations.reserve(plan.relations);
        _relationMembers.reserve(plan.relations);

        _tags.reserve(plan.tags);
        _wayRefIds.reserve(plan.wayRefs);
        _wayLocations.reserve(plan.wayLocations);
        _relationMemberIds.reserve(plan.relationMembers);
        _relationMemberRoles.reserve(plan.relationMembers);
        _relationMemberTypes.reserve(plan.relationMembers);

        _nodeWayParents.reserveEdges(plan.wayRefs);
        _nodeRelationParents.reserveEdges(plan.relationNodeMembers);
        _wayRelationParents.reserveEdges(plan.relationWayMembers);
        _relationRelationParents.reserveEdges(plan.relationRelationMembers);

        _nodeIndex.prepare(plan.nodes);
        _wayIndex.prepare(plan.ways);
        _relationIndex.prepare(plan.relations);
    }

    Span32 _lastWayLocationSpan;

    @property Span32 lastWayLocationSpan() const @safe pure nothrow @nogc
    {
        return _lastWayLocationSpan;
    }

    OsmHandle makeHandle(ElementType type, uint slot, uint generation)
        @safe nothrow @nogc
    {
        OsmHandle result;
        result._type = type;
        result._slot = slot;
        result._generation = generation;
        result._epoch = _epoch;
        return result;
    }

    bool preflightIdAndTags(
        ElementType type,
        OsmId id,
        scope const(OwnedTag)[] tags,
        ref StoreStatus status) @safe nothrow @nogc
    {
        if (id == 0)
        {
            status.error = StoreError.invalidId;
            return false;
        }

        OsmHandle existing;
        if (find(type, id, existing))
        {
            status.error = StoreError.duplicateId;
            return false;
        }

        return preflightTags(tags, status);
    }

    bool preflightTags(
        scope const(OwnedTag)[] tags,
        ref StoreStatus status) @safe pure nothrow @nogc
    {
        foreach (i, ref const tag; tags)
        {
            if (tag.key.length == 0)
            {
                status.error = StoreError.emptyTagKey;
                return false;
            }

            foreach (j; 0 .. i)
            {
                if (sameBytes(tags[j].key, tag.key))
                {
                    status.error = StoreError.duplicateTagKey;
                    return false;
                }
            }
        }
        return true;
    }

    bool preflightWayReferences(
        scope const(OwnedWayNode)[] nodes,
        ref StoreStatus status) @safe nothrow @nogc
    {
        foreach (ref const node; nodes)
        {
            if (node.id >= 0)
                continue;

            uint slot;
            if (!_nodeIndex.find(node.id, slot))
            {
                status.error = StoreError.unresolvedLocalReference;
                status.type = ElementType.node;
                status.id = node.id;
                return false;
            }
        }
        return true;
    }

    bool preflightRelationMembers(
        scope const(OwnedRelationMember)[] members,
        ref StoreStatus status) @safe nothrow @nogc
    {
        foreach (ref const member; members)
        {
            if (member.id >= 0)
                continue;

            uint slot;
            bool found;
            final switch (member.type)
            {
                case ElementType.node:
                    found = _nodeIndex.find(member.id, slot);
                    break;
                case ElementType.way:
                    found = _wayIndex.find(member.id, slot);
                    break;
                case ElementType.relation:
                    found = _relationIndex.find(member.id, slot);
                    break;
            }

            if (!found)
            {
                status.error = StoreError.unresolvedLocalReference;
                status.type = member.type;
                status.id = member.id;
                return false;
            }
        }
        return true;
    }


    bool preflightBorrowedIdentity(
        ElementType type,
        OsmId id,
        ref StoreStatus status) @safe nothrow @nogc
    {
        if (id <= 0)
        {
            status.error = StoreError.invalidId;
            return false;
        }

        OsmHandle existing;
        if (find(type, id, existing))
        {
            status.error = StoreError.duplicateId;
            return false;
        }

        return true;
    }

    bool preflightBorrowedTags(Range)(
        Range source,
        ref StoreStatus status) @safe nothrow @nogc
    {
        auto outer = source;
        while (!outer.empty)
        {
            const tag = outer.front;
            if (tag.key.length == 0)
            {
                status.error = StoreError.emptyTagKey;
                return false;
            }

            auto inner = outer;
            inner.popFront();
            while (!inner.empty)
            {
                if (sameBytes(tag.key, inner.front.key))
                {
                    status.error = StoreError.duplicateTagKey;
                    return false;
                }
                inner.popFront();
            }

            outer.popFront();
        }
        return true;
    }

    ref ParentIndex relationParentIndex(ElementType type)
        @safe nothrow @nogc
    {
        final switch (type)
        {
            case ElementType.node:
                return _nodeRelationParents;
            case ElementType.way:
                return _wayRelationParents;
            case ElementType.relation:
                return _relationRelationParents;
        }
    }

    ParentEdge relationParentEdge(ElementType type, uint encoded)
        @safe nothrow @nogc
    {
        final switch (type)
        {
            case ElementType.node:
                return _nodeRelationParents.edge(encoded);
            case ElementType.way:
                return _wayRelationParents.edge(encoded);
            case ElementType.relation:
                return _relationRelationParents.edge(encoded);
        }
    }

    uint relationParentHead(ElementType type, OsmId id)
        @safe nothrow @nogc
    {
        final switch (type)
        {
            case ElementType.node:
                return _nodeRelationParents.head(id);
            case ElementType.way:
                return _wayRelationParents.head(id);
            case ElementType.relation:
                return _relationRelationParents.head(id);
        }
    }

    void deactivateWayParents(Span32 refs, uint parentSlot)
        @safe nothrow @nogc
    {
        foreach (i; 0 .. refs.length)
        {
            const childIndex = refs.offset + i;
            _nodeWayParents.deactivate(
                _wayRefIds[childIndex],
                parentSlot);
        }
    }

    void reactivateWayParents(Span32 refs, uint parentSlot)
        @safe nothrow @nogc
    {
        foreach (i; 0 .. refs.length)
        {
            const childIndex = refs.offset + i;
            _nodeWayParents.insert(
                _wayRefIds[childIndex],
                parentSlot);
        }
    }

    void deactivateRelationParents(Span32 members, uint parentSlot)
        @safe nothrow @nogc
    {
        foreach (i; 0 .. members.length)
        {
            const childIndex = members.offset + i;
            const type =
                cast(ElementType)_relationMemberTypes[childIndex];
            relationParentIndex(type).deactivate(
                _relationMemberIds[childIndex],
                parentSlot);
        }
    }

    void reactivateRelationParents(Span32 members, uint parentSlot)
        @safe nothrow @nogc
    {
        foreach (i; 0 .. members.length)
        {
            const childIndex = members.offset + i;
            const type =
                cast(ElementType)_relationMemberTypes[childIndex];
            relationParentIndex(type).insert(
                _relationMemberIds[childIndex],
                parentSlot);
        }
    }

    static void prepareParentMove(
        ref ParentIndex index,
        OsmId oldId,
        OsmId newId) @safe nothrow @nogc
    {
        index.reserveAdditionalEdges(index.edgeCount(oldId));
        index.ensureKey(newId);
    }

    void moveWayParentKey(OsmId oldId, OsmId newId)
        @safe nothrow @nogc
    {
        auto current = _nodeWayParents.head(oldId);
        while (current != 0)
        {
            const edge = _nodeWayParents.edge(current);
            const next = edge.next;

            bool belongsToCurrentState;
            if (edge.parentSlot < _wayRefs.length)
            {
                const span = _wayRefs[edge.parentSlot];
                foreach (i; 0 .. span.length)
                {
                    const childIndex = span.offset + i;
                    if (_wayRefIds[childIndex] == oldId)
                    {
                        _wayRefIds[childIndex] = newId;
                        belongsToCurrentState = true;
                    }
                }
            }

            if (belongsToCurrentState)
            {
                _nodeWayParents.insert(
                    newId,
                    edge.parentSlot,
                    edge.active);
                _nodeWayParents.deactivateEncoded(current);
            }

            current = next;
        }
    }

    void moveRelationParentKey(
        ElementType childType,
        OsmId oldId,
        OsmId newId) @safe nothrow @nogc
    {
        auto current = relationParentIndex(childType).head(oldId);

        while (current != 0)
        {
            const edge = relationParentIndex(childType).edge(current);
            const next = edge.next;

            bool belongsToCurrentState;
            if (edge.parentSlot < _relationMembers.length)
            {
                const span = _relationMembers[edge.parentSlot];
                foreach (i; 0 .. span.length)
                {
                    const childIndex = span.offset + i;
                    if (_relationMemberIds[childIndex] == oldId &&
                        cast(ElementType)_relationMemberTypes[childIndex] ==
                            childType)
                    {
                        _relationMemberIds[childIndex] = newId;
                        belongsToCurrentState = true;
                    }
                }
            }

            if (belongsToCurrentState)
            {
                relationParentIndex(childType).insert(
                    newId, edge.parentSlot, edge.active);
                relationParentIndex(childType).deactivateEncoded(current);
            }

            current = next;
        }
    }

    Span32 appendBorrowedTags(Range)(Range source)
        @safe nothrow @nogc
    {
        Span32 result;
        result.offset = cast(uint)_tags.length;

        while (!source.empty)
        {
            const value = source.front;
            CompactTag tag;
            tag.key = _strings.intern(value.key);
            tag.value = _strings.intern(value.value);
            _tags ~= tag;
            ++result.length;
            source.popFront();
        }

        return result;
    }


    bool preflightBorrowedWayNodes(Range)(
        Range source,
        ref StoreStatus status) @safe nothrow @nogc
    {
        while (!source.empty)
        {
            const value = source.front;
            if (value.id <= 0)
            {
                status.error = StoreError.unresolvedLocalReference;
                status.type = ElementType.node;
                status.id = value.id;
                return false;
            }
            source.popFront();
        }
        return true;
    }

    bool preflightBorrowedRelationMembers(Range)(
        Range source,
        ref StoreStatus status) @safe nothrow @nogc
    {
        while (!source.empty)
        {
            const value = source.front;
            if (value.id <= 0)
            {
                status.error = StoreError.unresolvedLocalReference;
                status.type = value.type;
                status.id = value.id;
                return false;
            }
            source.popFront();
        }
        return true;
    }

    Span32 appendBorrowedWayNodes(Range)(
        Range source,
        uint parentSlot) @safe nothrow @nogc
    {
        Span32 refs;
        refs.offset = cast(uint)_wayRefIds.length;

        Span32 locations;
        locations.offset = cast(uint)_wayLocations.length;

        uint relativeIndex;
        while (!source.empty)
        {
            const value = source.front;
            _wayRefIds ~= value.id;
            _nodeWayParents.insert(value.id, parentSlot);
            ++refs.length;

            if (value.hasLocation)
            {
                SparseWayLocation entry;
                entry.relativeIndex = relativeIndex;
                entry.latitudeNanodegrees =
                    value.location.latitudeNanodegrees;
                entry.longitudeNanodegrees =
                    value.location.longitudeNanodegrees;
                _wayLocations ~= entry;
            }

            ++relativeIndex;
            source.popFront();
        }

        locations.length = cast(uint)_wayLocations.length - locations.offset;
        _lastWayLocationSpan = locations;
        return refs;
    }

    Span32 appendBorrowedRelationMembers(Range)(
        Range source,
        uint parentSlot) @safe nothrow @nogc
    {
        Span32 result;
        result.offset = cast(uint)_relationMemberIds.length;

        while (!source.empty)
        {
            const value = source.front;
            _relationMemberIds ~= value.id;
            _relationMemberTypes ~= cast(ubyte)value.type;
            _relationMemberRoles ~= _strings.intern(value.role);
            relationParentIndex(value.type).insert(
                value.id,
                parentSlot);
            ++result.length;
            source.popFront();
        }

        return result;
    }

    Span32 appendTags(scope const(OwnedTag)[] values) @safe
    {
        assert(_tags.length <= uint.max);
        assert(values.length <= uint.max);
        assert(_tags.length + values.length <= uint.max);

        Span32 result;
        result.offset = cast(uint)_tags.length;
        result.length = cast(uint)values.length;

        foreach (ref const value; values)
        {
            CompactTag tag;
            tag.key = _strings.intern(value.key);
            tag.value = _strings.intern(value.value);
            _tags ~= tag;
        }

        return result;
    }

    Span32 appendWayNodes(
        scope const(OwnedWayNode)[] values,
        uint parentSlot) @safe
    {
        assert(_wayRefIds.length <= uint.max);
        assert(values.length <= uint.max);
        assert(_wayRefIds.length + values.length <= uint.max);
        assert(_wayLocations.length <= uint.max);

        Span32 refs;
        refs.offset = cast(uint)_wayRefIds.length;
        refs.length = cast(uint)values.length;

        Span32 locations;
        locations.offset = cast(uint)_wayLocations.length;

        foreach (i, ref const value; values)
        {
            _wayRefIds ~= value.id;
            _nodeWayParents.insert(value.id, parentSlot);

            if (value.hasLocation)
            {
                SparseWayLocation entry;
                entry.relativeIndex = cast(uint)i;
                entry.latitudeNanodegrees =
                    value.location.latitudeNanodegrees;
                entry.longitudeNanodegrees =
                    value.location.longitudeNanodegrees;
                _wayLocations ~= entry;
            }
        }

        locations.length = cast(uint)_wayLocations.length - locations.offset;
        _lastWayLocationSpan = locations;
        return refs;
    }

    Span32 appendRelationMembers(
        scope const(OwnedRelationMember)[] values,
        uint parentSlot) @safe
    {
        assert(_relationMemberIds.length <= uint.max);
        assert(values.length <= uint.max);
        assert(_relationMemberIds.length + values.length <= uint.max);

        Span32 result;
        result.offset = cast(uint)_relationMemberIds.length;
        result.length = cast(uint)values.length;

        foreach (ref const value; values)
        {
            _relationMemberIds ~= value.id;
            _relationMemberTypes ~= cast(ubyte)value.type;
            _relationMemberRoles ~= _strings.intern(value.role);
            relationParentIndex(value.type).insert(
                value.id,
                parentSlot);
        }

        return result;
    }

    StoreTagView tagAt(uint index) @safe nothrow @nogc
    {
        const tag = _tags[index];
        StoreTagView result;
        result.key = _strings.get(tag.key);
        result.value = _strings.get(tag.value);
        return result;
    }

    StoreTagRange tagRange(Span32 span) @safe nothrow @nogc
    {
        StoreTagRange result;
        result._store = this;
        result._offset = span.offset;
        result._length = span.length;
        return result;
    }

    StoreWayNodeRange wayNodeRange(uint slot) @safe nothrow @nogc
    {
        const refs = _wayRefs[slot];
        const locations = _wayLocationSpans[slot];
        StoreWayNodeRange result;
        result._store = this;
        result._refOffset = refs.offset;
        result._refLength = refs.length;
        result._locationOffset = locations.offset;
        result._locationLength = locations.length;
        return result;
    }

    StoreRelationMemberRange relationMemberRange(uint slot)
        @safe nothrow @nogc
    {
        const members = _relationMembers[slot];
        StoreRelationMemberRange result;
        result._store = this;
        result._offset = members.offset;
        result._length = members.length;
        return result;
    }

    StoreNodeView nodeViewAt(uint slot) @safe nothrow @nogc
    {
        StoreNodeView result;
        result.handle = makeHandle(
            ElementType.node, slot, _nodes.generations[slot]);
        result.id = _nodes.ids[slot];
        result.location = LocationView(
            _nodeLatitudes[slot], _nodeLongitudes[slot]);
        result.metadata = _nodes.metadata.view(slot, _strings);
        result.tags = tagRange(_nodes.tags[slot]);
        result.state = _nodes.states[slot];
        return result;
    }

    StoreWayView wayViewAt(uint slot) @safe nothrow @nogc
    {
        StoreWayView result;
        result.handle = makeHandle(
            ElementType.way, slot, _ways.generations[slot]);
        result.id = _ways.ids[slot];
        result.metadata = _ways.metadata.view(slot, _strings);
        result.tags = tagRange(_ways.tags[slot]);
        result.nodes = wayNodeRange(slot);
        result.state = _ways.states[slot];
        return result;
    }

    StoreRelationView relationViewAt(uint slot) @safe nothrow @nogc
    {
        StoreRelationView result;
        result.handle = makeHandle(
            ElementType.relation, slot, _relations.generations[slot]);
        result.id = _relations.ids[slot];
        result.metadata = _relations.metadata.view(slot, _strings);
        result.tags = tagRange(_relations.tags[slot]);
        result.members = relationMemberRange(slot);
        result.state = _relations.states[slot];
        return result;
    }

    OwnedTag[] copyTags(Span32 span) @safe
    {
        OwnedTag[] result;
        result.length = span.length;
        foreach (i; 0 .. span.length)
        {
            const tag = _tags[span.offset + i];
            result[i].key = _strings.get(tag.key).idup;
            result[i].value = _strings.get(tag.value).idup;
        }
        return result;
    }

    OwnedNode copyNodeAt(uint slot) @safe
    {
        OwnedNode result;
        result.id = _nodes.ids[slot];
        result.location = LocationView(
            _nodeLatitudes[slot], _nodeLongitudes[slot]);
        result.metadata = _nodes.metadata.owned(slot, _strings);
        result.tags = copyTags(_nodes.tags[slot]);
        return result;
    }

    OwnedWay copyWayAt(uint slot) @safe
    {
        OwnedWay result;
        result.id = _ways.ids[slot];
        result.metadata = _ways.metadata.owned(slot, _strings);
        result.tags = copyTags(_ways.tags[slot]);

        auto range = wayNodeRange(slot);
        result.nodes.length = range.length;
        size_t i;
        while (!range.empty)
        {
            const value = range.front;
            result.nodes[i].id = value.id;
            result.nodes[i].hasLocation = value.hasLocation;
            if (value.hasLocation)
                result.nodes[i].location = value.location;
            ++i;
            range.popFront();
        }

        return result;
    }

    OwnedRelation copyRelationAt(uint slot) @safe
    {
        OwnedRelation result;
        result.id = _relations.ids[slot];
        result.metadata = _relations.metadata.owned(slot, _strings);
        result.tags = copyTags(_relations.tags[slot]);

        auto range = relationMemberRange(slot);
        result.members.length = range.length;
        size_t i;
        while (!range.empty)
        {
            const value = range.front;
            result.members[i].type = value.type;
            result.members[i].id = value.id;
            result.members[i].role = value.role.idup;
            ++i;
            range.popFront();
        }

        return result;
    }

    void captureNodeBaseline(uint slot) @safe
    {
        if (_nodes.states[slot] != StoreElementState.clean ||
            slot in _nodeBaselines)
            return;
        _nodeBaselines[slot] = copyNodeAt(slot);
    }

    void captureWayBaseline(uint slot) @safe
    {
        if (_ways.states[slot] != StoreElementState.clean ||
            slot in _wayBaselines)
            return;
        _wayBaselines[slot] = copyWayAt(slot);
    }

    void captureRelationBaseline(uint slot) @safe
    {
        if (_relations.states[slot] != StoreElementState.clean ||
            slot in _relationBaselines)
            return;
        _relationBaselines[slot] = copyRelationAt(slot);
    }

    static void markModified(ref CommonColumns columns, uint slot)
        @safe nothrow @nogc
    {
        if (columns.states[slot] == StoreElementState.clean)
            columns.states[slot] = StoreElementState.modified;
    }

    static void setAuthoritativeVersion(
        ref CommonColumns columns,
        uint slot,
        int versionNumber) @safe nothrow @nogc
    {
        columns.metadata.flags[slot] |= 1;
        columns.metadata.versions[slot] = versionNumber;
    }

    bool validateHandle(
        OsmHandle handle,
        ref StoreStatus status) @safe nothrow @nogc
    {
        if (!handle.valid || handle._epoch != _epoch)
        {
            status.error = StoreError.invalidHandle;
            return false;
        }

        final switch (handle.type)
        {
            case ElementType.node:
                if (handle._slot >= _nodes.ids.length ||
                    _nodes.generations[handle._slot] != handle._generation)
                {
                    status.error = StoreError.invalidHandle;
                    return false;
                }
                break;
            case ElementType.way:
                if (handle._slot >= _ways.ids.length ||
                    _ways.generations[handle._slot] != handle._generation)
                {
                    status.error = StoreError.invalidHandle;
                    return false;
                }
                break;
            case ElementType.relation:
                if (handle._slot >= _relations.ids.length ||
                    _relations.generations[handle._slot] != handle._generation)
                {
                    status.error = StoreError.invalidHandle;
                    return false;
                }
                break;
        }

        status.type = handle.type;
        status.id = idAt(handle);
        return true;
    }

    bool validateLiveHandle(
        OsmHandle handle,
        ElementType expected,
        ref StoreStatus status) @safe nothrow @nogc
    {
        if (!validateHandle(handle, status))
            return false;

        if (handle.type != expected)
        {
            status.error = StoreError.wrongElementType;
            return false;
        }

        if (stateAt(handle) == StoreElementState.deleted)
        {
            status.error = StoreError.deletedElement;
            return false;
        }

        return true;
    }

    StoreElementState stateAt(OsmHandle handle) @safe nothrow @nogc
    {
        final switch (handle.type)
        {
            case ElementType.node:
                return _nodes.states[handle._slot];
            case ElementType.way:
                return _ways.states[handle._slot];
            case ElementType.relation:
                return _relations.states[handle._slot];
        }
    }

    OsmId idAt(OsmHandle handle) @safe nothrow @nogc
    {
        final switch (handle.type)
        {
            case ElementType.node:
                return _nodes.ids[handle._slot];
            case ElementType.way:
                return _ways.ids[handle._slot];
            case ElementType.relation:
                return _relations.ids[handle._slot];
        }
    }

    static size_t ownedMetadataBytes(scope ref const OwnedMetadata value)
        @safe pure nothrow @nogc
    {
        return OwnedMetadata.sizeof +
               (value.hasUsername ? value.username.length : 0);
    }

    static size_t ownedTagBytes(scope ref const OwnedTag value)
        @safe pure nothrow @nogc
    {
        return OwnedTag.sizeof + value.key.length + value.value.length;
    }

    static size_t ownedNodeBytes(scope ref const OwnedNode value)
        @safe pure nothrow @nogc
    {
        size_t result = OwnedNode.sizeof + ownedMetadataBytes(value.metadata);
        foreach (ref const tag; value.tags)
            result += ownedTagBytes(tag);
        return result;
    }

    static size_t ownedWayBytes(scope ref const OwnedWay value)
        @safe pure nothrow @nogc
    {
        size_t result = OwnedWay.sizeof + ownedMetadataBytes(value.metadata);
        result += value.nodes.length * OwnedWayNode.sizeof;
        foreach (ref const tag; value.tags)
            result += ownedTagBytes(tag);
        return result;
    }

    static size_t ownedRelationBytes(scope ref const OwnedRelation value)
        @safe pure nothrow @nogc
    {
        size_t result =
            OwnedRelation.sizeof + ownedMetadataBytes(value.metadata);
        foreach (ref const tag; value.tags)
            result += ownedTagBytes(tag);
        foreach (ref const member; value.members)
            result += OwnedRelationMember.sizeof + member.role.length;
        return result;
    }
}

unittest
{
    import osm.model.owned : ownBytes;

    auto store = new OsmStore();

    OwnedNode node;
    node.id = 1;
    node.location = LocationView(48_208_174_300L, 16_373_818_900L);
    node.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"A"));

    OsmHandle nodeHandle;
    StoreStatus status;
    assert(store.add(node, nodeHandle, status));
    assert(status.ok);
    assert(nodeHandle.valid);

    OsmHandle found;
    assert(store.find(ElementType.node, 1, found));
    assert(found == nodeHandle);

    StoreNodeView view;
    assert(store.node(found, view, status));
    assert(view.id == 1);
    assert(view.location.latitudeNanodegrees == 48_208_174_300L);
    assert(!view.tags.empty);
    assert(view.tags.front.key == cast(const(ubyte)[])"name");

    node.location = LocationView(48_000_000_000L, 16_000_000_000L);
    assert(store.replace(nodeHandle, node, status));
    assert(store.node(nodeHandle, view, status));
    assert(view.state == StoreElementState.modified);
    assert(view.location.latitudeNanodegrees == 48_000_000_000L);

    assert(store.remove(nodeHandle, status));
    assert(!store.find(ElementType.node, 1, found));
    StoreElementState lifecycle;
    assert(store.state(nodeHandle, lifecycle, status));
    assert(lifecycle == StoreElementState.deleted);

    assert(store.restore(nodeHandle, status));
    assert(store.find(ElementType.node, 1, found));
    assert(found == nodeHandle);
}

unittest
{
    auto store = new OsmStore();

    OwnedNode localNode;
    localNode.id = -1;
    localNode.location = LocationView(1, 2);

    OsmHandle nodeHandle;
    StoreStatus status;
    assert(store.add(localNode, nodeHandle, status));

    OwnedWay way;
    way.id = -2;
    OwnedWayNode refValue;
    refValue.id = -1;
    way.nodes ~= refValue;

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    OwnedRelation relation;
    relation.id = -3;
    OwnedRelationMember member;
    member.type = ElementType.way;
    member.id = -2;
    relation.members ~= member;

    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    auto ways = store.ways;
    assert(!ways.empty);
    assert(ways.front.id == -2);
    assert(ways.front.nodes.front.id == -1);

    auto relations = store.relations;
    assert(!relations.empty);
    assert(relations.front.members.front.id == -2);
}


unittest
{
    // Handles are store-local even when slot/generation/type coincide.
    auto a = new OsmStore();
    auto b = new OsmStore();

    OwnedNode node;
    node.id = 7;
    node.location = LocationView(1, 2);

    OsmHandle handleA;
    OsmHandle handleB;
    StoreStatus status;
    assert(a.add(node, handleA, status));
    assert(b.add(node, handleB, status));
    assert(handleA != handleB);

    StoreNodeView view;
    assert(!b.node(handleA, view, status));
    assert(status.error == StoreError.invalidHandle);
}

unittest
{
    // Whole-dataset construction fails without exposing a partial store.
    OwnedDataset data;

    OwnedNode a;
    a.id = 1;
    a.location = LocationView(1, 2);
    data.nodes ~= a;

    OwnedNode duplicate = a;
    duplicate.location = LocationView(3, 4);
    data.nodes ~= duplicate;

    OsmStore store;
    StoreStatus status;
    assert(!OsmStore.build(data, store, status));
    assert(store is null);
    assert(status.error == StoreError.duplicateId);
}

unittest
{
    // First edit captures one baseline and revert restores semantic state.
    import osm.model.owned : ownBytes;

    auto store = new OsmStore();

    OwnedNode original;
    original.id = 11;
    original.location = LocationView(10, 20);
    original.tags ~= OwnedTag(
        ownBytes(cast(const(ubyte)[])"name"),
        ownBytes(cast(const(ubyte)[])"before"));

    OsmHandle handle;
    StoreStatus status;
    assert(store.add(original, handle, status));

    auto edited = original.deepCopy();
    edited.location = LocationView(30, 40);
    edited.tags[0].value = ownBytes(cast(const(ubyte)[])"after");
    assert(store.replace(handle, edited, status));

    StoreElementState lifecycle;
    assert(store.state(handle, lifecycle, status));
    assert(lifecycle == StoreElementState.modified);

    assert(store.revert(handle, status));
    assert(store.state(handle, lifecycle, status));
    assert(lifecycle == StoreElementState.clean);

    OwnedNode restored;
    assert(store.copyNode(handle, restored, status));
    assert(restored.location.latitudeNanodegrees == 10);
    assert(restored.location.longitudeNanodegrees == 20);
    assert(restored.tags[0].value == cast(const(ubyte)[])"before");
}

unittest
{
    // Parent navigation is distinct by parent and remains coherent under
    // replacement, deletion and restoration.
    auto store = new OsmStore();
    StoreStatus status;

    foreach (id; [1L, 2L])
    {
        OwnedNode node;
        node.id = id;
        node.location = LocationView(id, id);
        OsmHandle ignored;
        assert(store.add(node, ignored, status));
    }

    OwnedWay way;
    way.id = 10;
    way.nodes ~= OwnedWayNode(1, false, LocationView.init);
    way.nodes ~= OwnedWayNode(2, false, LocationView.init);
    way.nodes ~= OwnedWayNode(1, false, LocationView.init);

    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    auto parents1 = store.parentWays(1);
    assert(!parents1.empty);
    assert(parents1.front.handle == wayHandle);
    parents1.popFront();
    assert(parents1.empty);

    auto parents2 = store.parentWays(2);
    assert(!parents2.empty);
    assert(parents2.front.handle == wayHandle);

    OwnedWay replacement = way.deepCopy();
    replacement.nodes.length = 1;
    replacement.nodes[0].id = 2;
    assert(store.replace(wayHandle, replacement, status));

    assert(store.parentWays(1).empty);
    parents2 = store.parentWays(2);
    assert(!parents2.empty);
    assert(parents2.front.handle == wayHandle);

    assert(store.remove(wayHandle, status));
    assert(store.parentWays(2).empty);
    assert(store.restore(wayHandle, status));
    parents2 = store.parentWays(2);
    assert(!parents2.empty);
    assert(parents2.front.handle == wayHandle);
}

unittest
{
    // Relation parents are typed and may point at an unresolved positive child.
    auto store = new OsmStore();
    StoreStatus status;

    OwnedRelation relation;
    relation.id = 20;

    OwnedRelationMember nodeMember;
    nodeMember.type = ElementType.node;
    nodeMember.id = 999;
    relation.members ~= nodeMember;
    relation.members ~= nodeMember; // duplicate member, one distinct parent

    OwnedRelationMember wayMember;
    wayMember.type = ElementType.way;
    wayMember.id = 999;
    relation.members ~= wayMember;

    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    auto nodeParents = store.parentRelations(ElementType.node, 999);
    assert(!nodeParents.empty);
    assert(nodeParents.front.handle == relationHandle);
    nodeParents.popFront();
    assert(nodeParents.empty);

    auto wayParents = store.parentRelations(ElementType.way, 999);
    assert(!wayParents.empty);
    assert(wayParents.front.handle == relationHandle);

    assert(store.parentRelations(ElementType.relation, 999).empty);

    assert(store.remove(relationHandle, status));
    assert(store.parentRelations(ElementType.node, 999).empty);
    assert(store.restore(relationHandle, status));
    assert(!store.parentRelations(ElementType.node, 999).empty);
}

unittest
{
    // Public ID remapping discovers all inbound references through the
    // production indexes, updates tombstoned parents, and preserves handles.
    auto store = new OsmStore();
    StoreStatus status;

    OwnedNode node;
    node.id = -1;
    node.location = LocationView(1, 2);
    OsmHandle nodeHandle;
    assert(store.add(node, nodeHandle, status));

    OwnedWay way;
    way.id = -2;
    way.nodes ~= OwnedWayNode(-1, false, LocationView.init);
    way.nodes ~= OwnedWayNode(-1, false, LocationView.init);
    OsmHandle wayHandle;
    assert(store.add(way, wayHandle, status));

    OwnedRelation relation;
    relation.id = -3;

    OwnedRelationMember wayMember;
    wayMember.type = ElementType.way;
    wayMember.id = -2;
    relation.members ~= wayMember;

    OwnedRelationMember nodeMember;
    nodeMember.type = ElementType.node;
    nodeMember.id = -1;
    relation.members ~= nodeMember;

    OsmHandle relationHandle;
    assert(store.add(relation, relationHandle, status));

    // Deleted parents are not navigable, but their current forward state must
    // still participate in an authoritative child-ID remap.
    assert(store.remove(wayHandle, status));
    assert(store.parentWays(-1).empty);

    assert(store.remapId(nodeHandle, 101, 1, status));
    OsmHandle found;
    assert(store.find(ElementType.node, 101, found));
    assert(found == nodeHandle);
    assert(!store.find(ElementType.node, -1, found));

    assert(store.restore(wayHandle, status));
    auto wayParents = store.parentWays(101);
    assert(!wayParents.empty);
    assert(wayParents.front.handle == wayHandle);

    StoreWayView wayView;
    assert(store.way(wayHandle, wayView, status));
    auto refs = wayView.nodes;
    assert(refs.front.id == 101);
    refs.popFront();
    assert(refs.front.id == 101);

    StoreRelationView relationView;
    assert(store.relation(relationHandle, relationView, status));
    auto members = relationView.members;
    assert(members.front.id == -2);
    members.popFront();
    assert(members.front.id == 101);

    assert(store.remapId(wayHandle, 102, 1, status));
    assert(store.find(ElementType.way, 102, found));
    assert(found == wayHandle);

    auto relationParents = store.parentRelations(ElementType.way, 102);
    assert(!relationParents.empty);
    assert(relationParents.front.handle == relationHandle);

    assert(store.relation(relationHandle, relationView, status));
    members = relationView.members;
    assert(members.front.id == 102);

    assert(store.remapId(relationHandle, 103, 1, status));
    assert(store.find(ElementType.relation, 103, found));
    assert(found == relationHandle);

    // A second remap is rejected because the ID is no longer local.
    assert(!store.remapId(nodeHandle, 104, 2, status));
    assert(status.error == StoreError.invalidId);
}
