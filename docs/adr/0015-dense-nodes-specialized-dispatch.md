# ADR 0015: DenseNodes specialized dispatch boundary

- Status: Accepted
- Date: 2026-09-13

## Context

DenseNodes decoding uses four compile-time capability variants for the presence
or absence of tags and DenseInfo. Specialization removes irrelevant cursor work
from the per-node loop and is important for throughput.

Forcing every `emitDenseNodes!(HasTags, HasInfo)` specialization to inline
directly into `decodeDenseNodes` caused the runtime dispatcher to contain all
four large hot loops. In the measured LDC/LTO build the resulting production
function expanded to more than twenty thousand static instructions. Moving the
emitter completely out of line fixed the code-size problem but caused a
repeatable throughput regression across realistic tagged profiles.

## Decision

Keep a two-level boundary:

1. `decodeDenseNodes` completes preflight validation and determines the runtime
   `hasTags` / `hasInfo` capability state.
2. It calls `dispatchDenseNodes!(HasTags, HasInfo)`, which is explicitly
   `pragma(inline, false)`.
3. The selected `emitDenseNodes!(HasTags, HasInfo)` remains explicitly
   `pragma(inline, true)` and is optimized inside that specialized wrapper.

The boundary changes code generation only. It does not change preflight,
validation, error handling, allocation behavior, or sink semantics.

## Consequences

- The public decoder/dispatcher remains compact instead of embedding all four
  specialized loops.
- Only the selected capability specialization executes for a DenseNodes group.
- The per-node emitter retains cross-function optimization, scalar replacement,
  and the scalar sink fast path.
- Realistic mixed DenseNodes are at C++ reference performance and the rich-tag
  profiles are faster in the recorded baseline; typical tagged data remains
  within a few percent of the C++ semantic reference.
- The synthetic tagless profile remains slower than the C++ reference. Further
  optimization of that outlier must not regress realistic tagged workloads or
  weaken the integrity contract.

## Alternatives considered

### Inline all emit variants into `decodeDenseNodes`

Rejected because it produces severe code-size expansion and poor production
code generation.

### Keep `emitDenseNodes` completely out of line

Rejected because controlled measurements showed a repeatable slowdown across
all realistic profiles despite the smaller dispatcher.

### Remove validation from the fast path

Rejected. Preflight-before-emission and exact validation are data-integrity
requirements, not optional performance features.
