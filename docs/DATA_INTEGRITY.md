# Data Integrity Contract

## Principle

`osm-d` must never silently corrupt OSM data.

No field, tag, reference, relation member, metadata value, extension or source
feature may be discarded, repaired, reordered or approximated without an
explicit operation whose effect is visible to the caller.

When preservation cannot be guaranteed, the safe default is failure.

## Core invariants

### 1. No silent loss

Known data is retained. Unknown data is either preserved in a loss-aware raw
representation or causes a rewrite operation to fail.

### 2. No implicit repair

Malformed varints, inconsistent parallel arrays, duplicate tag keys, invalid
IDs, invalid coordinates and broken local references are reported. The parser
does not quietly "fix" them.

### 3. Exact before convenient

IDs and coordinates use exact integer/fixed-point representations in the
authoritative path. Floating-point coordinates are derived convenience values,
never the source of truth for a round trip.

### 4. Order is data

Way node references and relation members retain their order and duplicates.
Raw source order is retained when needed for a guaranteed round trip.

### 5. Partiality is explicit

The library distinguishes at least:

- a complete element from an unresolved referenced element;
- a complete dataset from a partial extract;
- current data from historical data;
- decoded data from validated data.

A missing referenced object must not be converted into an empty complete
object.

### 6. Unknown means preserve or fail

Unknown required PBF features are rejected. Unknown optional features may be
read when they do not affect interpretation, but a rewrite may proceed only if
their information can be preserved or the caller explicitly accepts loss.

### 7. Uploads use complete changed objects

OSM modify operations are not patches. Upload construction must therefore use
a known baseline and a complete resulting object. A partial local object must
never be serialized as a modification merely because the known fields look
valid.

### 8. Safe file replacement

Writers do not overwrite the only copy of an input file in place. Replacement
is performed through a completed temporary output followed by an atomic rename
where the platform permits it.

## Integrity states

The API should be able to express these independently:

```text
decodable
formatValid
validOsm
referentiallyComplete
semanticallyRoundtrippable
formatRoundtrippable
uploadable
```

A boolean `valid` is insufficient.

## Raw versus validated representations

The raw layer may represent input that the normal OSM model cannot safely
represent, for example duplicate tag keys or unknown extensions. Validation
converts raw input into stronger types only after their invariants are proven.

## Error policy

Hot-path decoding returns compact structured errors rather than allocating
exceptions. Public APIs may translate these into richer errors outside the
`@nogc` region.

Every error should carry enough context to locate the failing structure, such
as block sequence, byte offset, field number, element type and element ID when
known.

## Testing requirements

Integrity-critical behavior requires:

- unit tests;
- malformed-input tests;
- round-trip tests;
- differential tests against independent implementations;
- fuzzing of wire and format boundaries;
- regression fixtures for every discovered data-loss bug.

Passing a large Planet extract is not proof of conformance. Rare but legal
encodings must be tested deliberately.
