/**
 * Exact raw PBF preservation values.
 *
 * The raw layer owns source bytes that cannot be represented by the ordinary
 * semantic model. It deliberately does not claim that captured bytes form a
 * valid or semantically understood OSM PBF file.
 *
 * Authors: Alexander Bernardi
 * Date: 2026-11-03
 * Copyright: Copyright © 2026 Alexander Bernardi
 * License: MIT
 */
module osm.raw.pbf;

/** Why a semantic rewrite must not discard the exact captured source. */
enum PbfPreservationReason : ubyte
{
    /// No unrepresented source content is currently known.
    none,

    /// A protobuf field occurrence is not represented by the semantic model.
    unknownField,

    /// HeaderBlock contains an optional feature whose semantics are unknown.
    unknownOptionalFeature,

    /// A known PBF construct is intentionally unsupported by the semantic model.
    unsupportedSemanticContent,
}

/**
 * Exact owned source bytes.
 *
 * `.init` is an empty capture. `capture` performs no validation; callers may
 * therefore retain an otherwise unrepresentable or even malformed file exactly
 * for later inspection or byte-for-byte reproduction.
 */
struct PbfRawFile
{
    immutable(ubyte)[] bytes;

    /** Own an exact copy of `source`. */
    static PbfRawFile capture(scope const(ubyte)[] source) @safe
    {
        PbfRawFile result;
        result.bytes = source.idup;
        return result;
    }

    @property bool empty() const @safe pure nothrow @nogc
    {
        return bytes.length == 0;
    }
}

/**
 * Preservation state attached to a semantically decoded PBF document.
 *
 * If `reason != none`, semantic rewrite must fail unless a future codec can
 * merge the preserved payload safely. Exact-source reproduction remains valid.
 */
struct PbfPreservation
{
    PbfRawFile source;
    PbfPreservationReason reason;
    /**
     * File-block start offset containing the first rewrite-sensitive content.
     *
     * For compressed payloads the exact nested protobuf byte has no stable
     * file offset without referring to compressed representation, so this
     * deliberately identifies the enclosing PBF file block.
     */
    size_t firstSensitiveOffset;

    /** Whether a semantic rewrite may proceed without known silent loss. */
    @property bool semanticRewriteSafe() const @safe pure nothrow @nogc
    {
        return reason == PbfPreservationReason.none;
    }

    /** Whether exact source bytes are available. */
    @property bool hasSource() const @safe pure nothrow @nogc
    {
        return !source.empty;
    }
}

unittest
{
    const(ubyte)[] source = [1, 2, 3];
    auto raw = PbfRawFile.capture(source);
    assert(raw.bytes == source);

    PbfPreservation state;
    state.source = raw;
    assert(state.semanticRewriteSafe);
    assert(state.hasSource);

    state.reason = PbfPreservationReason.unknownField;
    assert(!state.semanticRewriteSafe);
}
