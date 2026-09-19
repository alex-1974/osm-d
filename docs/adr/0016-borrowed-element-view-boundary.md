# ADR 0016: ElementView is a format-independent borrowed-view contract

- Status: Accepted
- Date: 2026-09-19

## Context

The PBF vertical slice now decodes all three regular OSM element classes and
DenseNodes. The codec currently exposes concrete borrowed values such as
`DenseNodeView`, `NodeView`, `WayView` and `RelationView`.

The public architecture places `view/` above the format codecs:

```text
format codec
 -> raw representation
 -> validation
 -> borrowed OSM views
 -> owned model or compact store
```

The public streaming boundary is intended to expose borrowed OSM elements while
the inner decoder remains push-based and allocation-controlled.

That boundary must satisfy several constraints at once:

- represent the OSM identity `(ElementType, OsmId)` without narrowing IDs;
- preserve Node, Way and Relation as separate element types;
- remain borrowed and make lifetime compatible with D `scope`;
- avoid mandatory allocation or materialization;
- remain usable from `@safe nothrow @nogc` consumers where practical;
- keep `view/` independent of `io/pbf`, `io/xml` and other codecs;
- permit DenseNode and regular Node encodings to present the same semantic OSM
  element kind without requiring ordinary consumers to distinguish encodings;
- preserve exact coordinates, ordered tags, ordered way references, ordered
  relation members and explicit metadata presence;
- permit later XML and osmChange readers without making their public view types
  depend on PBF implementation details.

Several representation experiments were performed before committing source
changes.

### `std.sumtype.SumType`

`SumType!(DenseNodeView, NodeView, WayView, RelationView)` can store all current
PBF element views by value.

With DMD 2.111.0 and LDC 1.41.0:

- `DenseNodeView.sizeof == 288`;
- `NodeView.sizeof == 392`;
- `WayView.sizeof == 704`;
- `RelationView.sizeof == 704`;
- the four-alternative `SumType` is 712 bytes;
- construction and copying compile under `@safe nothrow @nogc`.

However, the tested Phobos `hasValue` and `match` operations do not satisfy the
required `@safe nothrow @nogc` call sites on either compiler. A generic wrapper
containing the `SumType` was 728 bytes.

### Opaque pointer/type erasure

An opaque pointer/type-erased handle was tested and rejected.

Introducing an `@trusted` pointer bridge erased the payload lifetime relationship
strongly enough that a handle referencing a local view could escape in cases
where the public borrowed API must prevent that. The design therefore cannot
provide the required lifetime contract.

### Inline tagged union

A custom inline tagged union preserves value semantics and avoids pointer
lifetime erasure.

A prototype containing the four current PBF payloads was 712 bytes and supported
construction, copying, element-type access and ID access from
`@safe nothrow @nogc` callers on both DMD and LDC.

The current concrete PBF payloads are all POD values:

- no elaborate assignment;
- no elaborate copy constructor;
- no elaborate destructor;
- alignment 8;
- borrowed indirections remain present through slices and nested ranges.

A union containing the four current PBF payloads is also POD, 704 bytes and
alignment 8 on both tested compilers.

This proves that an inline union is viable as a codec-internal representation.
It does not make a union of PBF types suitable as the format-independent public
boundary.

### DIP1000 lifetime contract

For references returned from inline borrowed values, the lifetime relationship
must be expressed explicitly.

Tests on DMD 2.111.0 and LDC 1.41.0 confirmed:

- local borrowed use is accepted;
- a returned reference may be tied to a `return ref scope` parameter;
- a struct-member reference accessor using `scope return` can tie the returned
  reference to `this`;
- returning a reference into a local borrowed view is rejected by both
  compilers.

A representative rejected case produced:

```text
Error: returning `identity(view)` escapes a reference to local variable `view`
```

Lifetime tests that depend on whole-source compiler rejection belong in separate
compile-fail test sources rather than only in `__traits(compiles)` expressions.

### Generic wrapper with private codec adapter

A generic public wrapper parameterized by a codec-private adapter was tested as
a possible way to hide codec implementation details:

```d
ElementView!Adapter
```

An external consumer could use the returned value through `auto` without naming
the private adapter directly, and both DMD and LDC compiled that consumer.

The representation nevertheless fails the public-boundary requirement. Separate
module compilation and symbol inspection showed that the adapter remains part of
the concrete type and symbol identity:

```text
view.ElementView!(codec.Adapter).ElementView
```

The private adapter is therefore only syntactically hidden. The public concrete
type and ABI remain codec-dependent.

### Existing range state

The current borrowed PBF ranges are POD value types but contain real PBF decoder
state:

- `TagRange` contains repeated-field protobuf cursors and `StringTableView`;
- `DenseTagRange` contains the DenseNodes `keys_vals` cursor and
  `StringTableView`;
- `WayRefRange` contains a signed-delta protobuf cursor and accumulator;
- `WayLocationRange` contains two signed-delta cursors plus coordinate
  reconstruction state;
- `RelationMemberRange` contains role/type/member-ID protobuf cursors,
  `StringTableView` and member-ID accumulation state.

Measured sizes are identical on DMD and LDC:

```text
StringTableView       32 bytes
TagRange             240 bytes
DenseTagRange        176 bytes
WayRefRange          104 bytes
WayLocationRange     224 bytes
RelationMemberRange  328 bytes
```

Moving those states into `view/` would not create format independence; it would
move PBF parsing machinery across the layer boundary.

### Structural compile-time contract

A final prototype treated the public boundary as a structural compile-time
contract rather than one mandatory concrete storage type.

The format-independent module defined only semantic primitives plus a predicate
over a candidate view type. Independent concrete PBF and XML-like view types
satisfied the same contract, and one generic consumer accepted both.

On both DMD 2.111.0 and LDC 1.41.0:

- the positive contract probe compiled under `@safe nothrow @nogc`;
- the format-independent contract imported no codec;
- one generic consumer accepted both concrete codec view types;
- the borrowed lifetime negative test was rejected for the intended local
  lifetime escape.

This is the first tested design that preserves codec independence, zero-copy
value semantics, static dispatch and compiler-checked borrowed lifetime without
introducing runtime type erasure.

## Decision

The public borrowed element boundary is a **format-independent structural
compile-time contract**, not a requirement that every codec return one identical
concrete `ElementView` storage type.

The `view/` layer defines the semantic vocabulary and contracts that concrete
borrowed element views must satisfy. It MUST NOT import PBF, XML or osmChange
modules merely to define those contracts.

The common semantic identity uses:

```d
alias OsmId = long;

enum ElementType : ubyte
{
    node,
    way,
    relation,
}
```

Negative IDs remain valid values. Element type is explicit and is never inferred
from the numeric ID.

A concrete codec defines its own borrowed element value types, provided those
types satisfy the format-independent element-view contract. The current PBF
`DenseNodeView`, `NodeView`, `WayView` and `RelationView` do so directly; a
future XML codec may use different concrete representations.

Common consumers SHOULD be written against that compile-time contract rather
than against a codec-specific concrete type when they require only common OSM
semantics.

The contract MUST at minimum permit a `@safe nothrow @nogc` consumer to obtain:

- `ElementType type`;
- `OsmId id`.

Further common semantic capabilities such as node coordinates, tags, metadata,
way references and relation members MUST be added only when there is a concrete
consumer or cross-codec requirement proving that the operation belongs in the
shared contract.

A concrete borrowed element view:

- MUST NOT own the underlying source data;
- MUST NOT perform implicit deep copies or per-element allocation;
- MUST preserve codec backing lifetime requirements;
- MUST remain a cheap value/cursor object where practical;
- MAY contain codec-specific cursor state internally;
- MAY expose additional codec-specific operations outside the common semantic
  contract.

The shared contract MUST NOT require a consumer to distinguish DenseNode from
regular Node merely to obtain ordinary OSM element identity. PBF encoding
provenance may remain available through PBF-specific APIs.

The shared contract MUST NOT use opaque pointer/type erasure whose safety relies
on an unenforced `@trusted` lifetime promise.

A template parameter that contains a private codec type is not considered a
format-independent concrete public type merely because callers can use it
through `auto`. Codec implementation types must not become part of the intended
shared type identity or ABI.

Codec-internal inline tagged unions remain permitted where they are the clearest
value representation. Any required `@trusted` union boundary MUST be minimal,
reviewed and justified by explicit active-member and lifetime invariants.

Borrowed references exposed by concrete view types MUST retain compiler-visible
lifetime relationships. Compile-fail tests MUST cover attempts to return
references into local borrowed views when such reference-returning APIs are
introduced.

## Consequences

There is no requirement for one concrete runtime `ElementView` object that can
store values from every current and future codec.

Instead:

```text
view/ semantic contract
        ^
        |
   +----+----+
   |         |
PBF view   XML view
   |         |
   +----+----+
        |
 generic consumer / owned model / compact store
```

This keeps codec parsing state in the codec that owns it while still allowing
shared consumers to operate on common OSM semantics through static dispatch.

The design avoids:

- runtime virtual dispatch;
- mandatory heap allocation;
- unsafe opaque payload pointers;
- PBF cursor types in `view/`;
- private codec adapters leaking into one supposedly universal concrete public
  wrapper type.

Different codec view types may have different sizes and internal layouts. That
is acceptable because the architectural contract is semantic and borrowed, not
a promise of one cross-codec binary layout.

The public range adapter planned for the production reader remains a separate
Phase 3 concern. Its element type may be codec-specific while still satisfying
the shared element-view contract.

Owned model materialization and direct compact-store sinks remain explicit
consumer paths. They do not require the borrowed codecs to first materialize a
universal intermediate representation.

Performance remains subject to measurement. The contract itself must not force a
representation change in an established codec hot path without benchmark
evidence.

## Alternatives considered

### One concrete union of PBF views

Rejected as the architectural public boundary. It would make the supposedly
format-independent representation depend directly on current PBF types and would
not naturally admit later XML/osmChange views.

A PBF-specific union may still be a valid implementation detail of a concrete
PBF element view.

### `std.sumtype.SumType`

Useful as a representation experiment, but not selected for the current
hot-path contract. In the tested compiler/Phobos versions, its normal
introspection and dispatch operations did not satisfy the required
`@safe nothrow @nogc` call sites.

### Opaque pointer/type-erased handle

Rejected. The tested `@trusted` bridge erased the lifetime relationship required
from the borrowed API.

### Generic wrapper parameterized by a private codec adapter

Rejected as the shared concrete public type. The adapter remains part of the
instantiated D type and symbol mangling even when consumers never spell its name.

### Move common cursor state into `view/`

Rejected. The existing range states encode protobuf field traversal, PBF
StringTable lookup and PBF delta reconstruction. Moving them would invert or blur
the layer boundary rather than create a format-independent abstraction.

### Heap-allocated polymorphic objects

Rejected for the streaming boundary because they introduce mandatory
per-element allocation, runtime indirection and less explicit ownership.

### Structural compile-time contract

Selected. It preserves static dispatch, borrowed value semantics and codec
independence while allowing concrete codecs to retain the cursor representations
required by their source formats.
