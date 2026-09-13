// SPDX-License-Identifier: MIT
//
// Semantically matched C++20 reference for the d-osm DenseNodes hot path.
//
// This benchmark intentionally mirrors the work performed by the production D
// decoder on the benchmark's canonical no-DenseInfo workloads: complete dense
// tag preflight before emission, checked delta/coordinate arithmetic, per-node
// tag-range construction, and the same observable sink checksums. Workload
// generation, PrimitiveBlock/PrimitiveGroup layout discovery and StringTable
// indexing remain outside the timed region, exactly as in dense_nodes.d.
//
// Authors: Alexander Bernardi
// Date: 2026-09-12
// Copyright: Copyright © 2026 Alexander Bernardi
// License: MIT

#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace {

using Byte = std::uint8_t;
using Bytes = std::span<const Byte>;

constexpr std::uint64_t kMixConstant = 0x9e3779b97f4a7c15ULL;

inline std::uint64_t mix(std::uint64_t state, std::uint64_t value) noexcept {
    return state ^ (value + kMixConstant + (state << 6) + (state >> 2));
}

struct Cursor {
    const Byte* begin = nullptr;
    const Byte* current = nullptr;
    const Byte* end = nullptr;

    Cursor() = default;
    explicit Cursor(Bytes bytes) noexcept
        : begin(bytes.data()), current(bytes.data()), end(bytes.data() + bytes.size()) {}

    [[nodiscard]] bool empty() const noexcept { return current == end; }
    [[nodiscard]] std::size_t remaining() const noexcept {
        return static_cast<std::size_t>(end - current);
    }
    [[nodiscard]] std::size_t offset() const noexcept {
        return static_cast<std::size_t>(current - begin);
    }
};

bool read_varint64(Cursor& cursor, std::uint64_t& value) noexcept {
    value = 0;
    unsigned shift = 0;
    for (unsigned i = 0; i < 10; ++i) {
        if (cursor.current == cursor.end) {
            return false;
        }
        const std::uint8_t byte = *cursor.current++;
        if (i == 9 && byte > 1) {
            return false;
        }
        value |= static_cast<std::uint64_t>(byte & 0x7fU) << shift;
        if ((byte & 0x80U) == 0) {
            return true;
        }
        shift += 7;
    }
    return false;
}

inline std::int64_t zigzag_decode64(std::uint64_t value) noexcept {
    return static_cast<std::int64_t>((value >> 1) ^ (~(value & 1ULL) + 1ULL));
}

bool read_svarint64(Cursor& cursor, std::int64_t& value) noexcept {
    std::uint64_t raw = 0;
    if (!read_varint64(cursor, raw)) {
        return false;
    }
    value = zigzag_decode64(raw);
    return true;
}

struct FieldHeader {
    std::uint32_t number = 0;
    std::uint32_t wire = 0;
};

bool read_field_header(Cursor& cursor, FieldHeader& field) noexcept {
    std::uint64_t raw = 0;
    if (!read_varint64(cursor, raw)) {
        return false;
    }
    field.number = static_cast<std::uint32_t>(raw >> 3);
    field.wire = static_cast<std::uint32_t>(raw & 7U);
    return field.number != 0;
}

bool read_length_delimited(Cursor& cursor, Bytes& out) noexcept {
    std::uint64_t size64 = 0;
    if (!read_varint64(cursor, size64)) {
        return false;
    }
    if (size64 > cursor.remaining()) {
        return false;
    }
    const auto size = static_cast<std::size_t>(size64);
    out = Bytes(cursor.current, size);
    cursor.current += size;
    return true;
}

bool skip_field_value(Cursor& cursor, const FieldHeader& field) noexcept {
    switch (field.wire) {
        case 0: {
            std::uint64_t ignored = 0;
            return read_varint64(cursor, ignored);
        }
        case 1:
            if (cursor.remaining() < 8) return false;
            cursor.current += 8;
            return true;
        case 2: {
            Bytes ignored;
            return read_length_delimited(cursor, ignored);
        }
        case 5:
            if (cursor.remaining() < 4) return false;
            cursor.current += 4;
            return true;
        default:
            return false;
    }
}

inline bool checked_add(std::int64_t a, std::int64_t b, std::int64_t& result) noexcept {
#if defined(__clang__) || defined(__GNUC__)
    return !__builtin_add_overflow(a, b, &result);
#else
    if ((b > 0 && a > std::numeric_limits<std::int64_t>::max() - b) ||
        (b < 0 && a < std::numeric_limits<std::int64_t>::min() - b)) {
        return false;
    }
    result = a + b;
    return true;
#endif
}

inline bool checked_mul_add(
    std::int64_t base,
    std::int64_t factor,
    std::int64_t value,
    std::int64_t& result) noexcept {
    std::int64_t product = 0;
#if defined(__clang__) || defined(__GNUC__)
    if (__builtin_mul_overflow(factor, value, &product)) return false;
#else
    const __int128 wide = static_cast<__int128>(factor) * static_cast<__int128>(value);
    if (wide < std::numeric_limits<std::int64_t>::min() ||
        wide > std::numeric_limits<std::int64_t>::max()) return false;
    product = static_cast<std::int64_t>(wide);
#endif
    return checked_add(base, product, result);
}

struct StringRef {
    std::uint32_t offset = 0;
    std::uint32_t length = 0;
};

struct StringTableView {
    const Byte* block_begin = nullptr;
    std::span<const StringRef> refs;

    [[nodiscard]] std::size_t length() const noexcept { return refs.size(); }

    bool get(std::size_t sid, Bytes& value) const noexcept {
        if (sid >= refs.size()) return false;
        const auto& ref = refs[sid];
        value = Bytes(block_begin + ref.offset, ref.length);
        return true;
    }
};

struct DenseLayout {
    std::size_t id_count = 0;
    std::size_t lat_count = 0;
    std::size_t lon_count = 0;
    std::size_t keys_vals_count = 0;
    std::size_t node_count = 0;
    std::int64_t min_lat = 0;
    std::int64_t max_lat = 0;
    std::int64_t min_lon = 0;
    std::int64_t max_lon = 0;
    bool has_lat_range = false;
    bool has_lon_range = false;
    bool has_dense_info = false;
};

struct GroupLayout {
    Bytes raw;
    DenseLayout dense;
    [[nodiscard]] bool has_dense_nodes() const noexcept { return dense.id_count != 0; }
};

struct BlockLayout {
    std::int32_t granularity = 100;
    std::int32_t date_granularity = 1000;
    std::int64_t lat_offset = 0;
    std::int64_t lon_offset = 0;
};

bool count_packed_svarints(
    Bytes bytes,
    std::size_t& count,
    std::int64_t& cumulative,
    std::int64_t& minimum,
    std::int64_t& maximum,
    bool& have_range) noexcept {
    Cursor cursor(bytes);
    while (!cursor.empty()) {
        std::int64_t delta = 0;
        if (!read_svarint64(cursor, delta)) return false;
        std::int64_t next = 0;
        if (!checked_add(cumulative, delta, next)) return false;
        cumulative = next;
        ++count;
        if (!have_range) {
            minimum = maximum = cumulative;
            have_range = true;
        } else {
            minimum = std::min(minimum, cumulative);
            maximum = std::max(maximum, cumulative);
        }
    }
    return true;
}

bool count_packed_varints(Bytes bytes, std::size_t& count) noexcept {
    Cursor cursor(bytes);
    while (!cursor.empty()) {
        std::uint64_t ignored = 0;
        if (!read_varint64(cursor, ignored)) return false;
        ++count;
    }
    return true;
}

bool scan_dense_layout(Bytes dense, DenseLayout& layout,
                       std::int64_t& id_accum,
                       std::int64_t& lat_accum,
                       std::int64_t& lon_accum) noexcept {
    Cursor cursor(dense);
    while (!cursor.empty()) {
        FieldHeader field;
        if (!read_field_header(cursor, field)) return false;

        if ((field.number == 1 || field.number == 8 || field.number == 9) &&
            field.wire == 2) {
            Bytes packed;
            if (!read_length_delimited(cursor, packed)) return false;
            if (field.number == 1) {
                std::int64_t unused_min = 0, unused_max = 0;
                bool unused_range = false;
                if (!count_packed_svarints(
                        packed, layout.id_count, id_accum,
                        unused_min, unused_max, unused_range)) return false;
            } else if (field.number == 8) {
                if (!count_packed_svarints(
                        packed, layout.lat_count, lat_accum,
                        layout.min_lat, layout.max_lat, layout.has_lat_range)) return false;
            } else {
                if (!count_packed_svarints(
                        packed, layout.lon_count, lon_accum,
                        layout.min_lon, layout.max_lon, layout.has_lon_range)) return false;
            }
            continue;
        }

        if ((field.number == 1 || field.number == 8 || field.number == 9) &&
            field.wire == 0) {
            std::int64_t delta = 0;
            if (!read_svarint64(cursor, delta)) return false;
            std::int64_t* accum = field.number == 1 ? &id_accum :
                                  field.number == 8 ? &lat_accum : &lon_accum;
            std::int64_t next = 0;
            if (!checked_add(*accum, delta, next)) return false;
            *accum = next;
            if (field.number == 1) {
                ++layout.id_count;
            } else if (field.number == 8) {
                ++layout.lat_count;
                if (!layout.has_lat_range) {
                    layout.min_lat = layout.max_lat = next;
                    layout.has_lat_range = true;
                } else {
                    layout.min_lat = std::min(layout.min_lat, next);
                    layout.max_lat = std::max(layout.max_lat, next);
                }
            } else {
                ++layout.lon_count;
                if (!layout.has_lon_range) {
                    layout.min_lon = layout.max_lon = next;
                    layout.has_lon_range = true;
                } else {
                    layout.min_lon = std::min(layout.min_lon, next);
                    layout.max_lon = std::max(layout.max_lon, next);
                }
            }
            continue;
        }

        if (field.number == 10 && field.wire == 2) {
            Bytes packed;
            if (!read_length_delimited(cursor, packed)) return false;
            if (!count_packed_varints(packed, layout.keys_vals_count)) return false;
            continue;
        }
        if (field.number == 10 && field.wire == 0) {
            std::uint64_t ignored = 0;
            if (!read_varint64(cursor, ignored)) return false;
            ++layout.keys_vals_count;
            continue;
        }
        if (field.number == 5 && field.wire == 2) {
            Bytes ignored;
            if (!read_length_delimited(cursor, ignored)) return false;
            layout.has_dense_info = true;
            continue;
        }
        if (!skip_field_value(cursor, field)) return false;
    }
    return true;
}

bool decode_group_layout(Bytes group, GroupLayout& layout) noexcept {
    layout = GroupLayout{};
    layout.raw = group;
    Cursor cursor(group);
    std::int64_t id_accum = 0;
    std::int64_t lat_accum = 0;
    std::int64_t lon_accum = 0;

    while (!cursor.empty()) {
        FieldHeader field;
        if (!read_field_header(cursor, field)) return false;
        if (field.number == 2 && field.wire == 2) {
            Bytes dense;
            if (!read_length_delimited(cursor, dense)) return false;
            if (!scan_dense_layout(dense, layout.dense, id_accum, lat_accum, lon_accum)) {
                return false;
            }
            continue;
        }
        if (!skip_field_value(cursor, field)) return false;
    }

    if (layout.dense.id_count != layout.dense.lat_count ||
        layout.dense.id_count != layout.dense.lon_count) return false;
    layout.dense.node_count = layout.dense.id_count;
    return true;
}

class DenseColumnCursor {
public:
    DenseColumnCursor(Bytes group, std::uint32_t field_number) noexcept
        : group_(group), field_number_(field_number) {}

    bool next(std::int64_t& value, bool& has_value) noexcept {
        value = 0;
        has_value = false;
        for (;;) {
            if (!packed_.empty()) {
                if (!read_svarint64(packed_, value)) return false;
                has_value = true;
                return true;
            }

            while (!dense_.empty()) {
                FieldHeader field;
                if (!read_field_header(dense_, field)) return false;
                if (field.number == field_number_ && field.wire == 0) {
                    if (!read_svarint64(dense_, value)) return false;
                    has_value = true;
                    return true;
                }
                if (field.number == field_number_ && field.wire == 2) {
                    Bytes packed;
                    if (!read_length_delimited(dense_, packed)) return false;
                    packed_ = Cursor(packed);
                    if (!packed_.empty()) break;
                    continue;
                }
                if (!skip_field_value(dense_, field)) return false;
            }
            if (!packed_.empty()) continue;

            bool found_dense = false;
            while (!group_.empty()) {
                FieldHeader field;
                if (!read_field_header(group_, field)) return false;
                if (field.number == 2 && field.wire == 2) {
                    Bytes dense;
                    if (!read_length_delimited(group_, dense)) return false;
                    dense_ = Cursor(dense);
                    found_dense = true;
                    break;
                }
                if (!skip_field_value(group_, field)) return false;
            }
            if (!found_dense) return true;
        }
    }

private:
    Cursor group_;
    Cursor dense_;
    Cursor packed_;
    std::uint32_t field_number_ = 0;
};

class KeysValsCursor {
public:
    explicit KeysValsCursor(Bytes group) noexcept : group_(group) {}

    bool next(std::uint64_t& value, bool& has_value) noexcept {
        value = 0;
        has_value = false;
        for (;;) {
            if (!packed_.empty()) {
                if (!read_varint64(packed_, value)) return false;
                has_value = true;
                return true;
            }

            while (!dense_.empty()) {
                FieldHeader field;
                if (!read_field_header(dense_, field)) return false;
                if (field.number == 10 && field.wire == 0) {
                    if (!read_varint64(dense_, value)) return false;
                    has_value = true;
                    return true;
                }
                if (field.number == 10 && field.wire == 2) {
                    Bytes packed;
                    if (!read_length_delimited(dense_, packed)) return false;
                    packed_ = Cursor(packed);
                    if (!packed_.empty()) break;
                    continue;
                }
                if (!skip_field_value(dense_, field)) return false;
            }
            if (!packed_.empty()) continue;

            bool found_dense = false;
            while (!group_.empty()) {
                FieldHeader field;
                if (!read_field_header(group_, field)) return false;
                if (field.number == 2 && field.wire == 2) {
                    Bytes dense;
                    if (!read_length_delimited(group_, dense)) return false;
                    dense_ = Cursor(dense);
                    found_dense = true;
                    break;
                }
                if (!skip_field_value(group_, field)) return false;
            }
            if (!found_dense) return true;
        }
    }

private:
    Cursor group_;
    Cursor dense_;
    Cursor packed_;
};

struct DenseTagView {
    std::uint32_t key_sid = 0;
    std::uint32_t value_sid = 0;
    Bytes key;
    Bytes value;
};

bool validate_string_id(std::uint64_t raw, const StringTableView& table,
                        std::uint32_t& sid) noexcept {
    if (raw == 0 || raw > static_cast<std::uint64_t>(std::numeric_limits<std::int32_t>::max())) {
        return false;
    }
    sid = static_cast<std::uint32_t>(raw);
    return sid < table.length();
}

bool decode_validated_pair(KeysValsCursor& stream, const StringTableView& table,
                           DenseTagView& tag) noexcept {
    std::uint64_t key_raw = 0, value_raw = 0;
    bool has_key = false, has_value = false;
    if (!stream.next(key_raw, has_key) || !has_key || key_raw == 0) return false;
    if (!stream.next(value_raw, has_value) || !has_value || value_raw == 0) return false;
    std::uint32_t key_sid = 0, value_sid = 0;
    if (!validate_string_id(key_raw, table, key_sid) ||
        !validate_string_id(value_raw, table, value_sid)) return false;
    Bytes key, value;
    if (!table.get(key_sid, key) || !table.get(value_sid, value)) return false;
    tag = DenseTagView{key_sid, value_sid, key, value};
    return true;
}

class DenseTagRange {
public:
    DenseTagRange() = default;

    [[nodiscard]] bool empty() const noexcept { return remaining_ == 0; }
    [[nodiscard]] std::size_t length() const noexcept { return remaining_; }
    [[nodiscard]] const DenseTagView& front() const noexcept { return front_; }

    void pop_front() noexcept {
        if (remaining_ == 0) return;
        --remaining_;
        if (remaining_ == 0) {
            front_ = DenseTagView{};
            return;
        }
        DenseTagView next;
        if (!decode_validated_pair(stream_, *table_, next)) {
            remaining_ = 0;
            front_ = DenseTagView{};
            return;
        }
        front_ = next;
    }

    static bool from_validated(KeysValsCursor stream, const StringTableView& table,
                               std::size_t pair_count, DenseTagRange& range) noexcept {
        range = DenseTagRange{};
        range.stream_ = stream;
        range.table_ = &table;
        range.remaining_ = pair_count;
        if (pair_count != 0) {
            if (!decode_validated_pair(range.stream_, table, range.front_)) {
                range = DenseTagRange{};
                return false;
            }
        }
        return true;
    }

private:
    KeysValsCursor stream_{Bytes{}};
    const StringTableView* table_ = nullptr;
    DenseTagView front_{};
    std::size_t remaining_ = 0;
};

struct DenseTagValidationSummary {
    std::size_t node_segments = 0;
    std::size_t tag_count = 0;
    std::size_t encoded_value_count = 0;
};

bool validate_dense_tags(const GroupLayout& group, const StringTableView& table,
                         DenseTagValidationSummary& summary) noexcept {
    summary = DenseTagValidationSummary{};
    if (!group.has_dense_nodes() || group.dense.keys_vals_count == 0) return true;

    KeysValsCursor stream(group.raw);
    bool waiting_for_value = false;
    for (;;) {
        std::uint64_t raw = 0;
        bool has_value = false;
        if (!stream.next(raw, has_value)) return false;
        if (!has_value) break;
        ++summary.encoded_value_count;

        if (raw == 0) {
            if (waiting_for_value) return false;
            ++summary.node_segments;
            if (summary.node_segments > group.dense.node_count) return false;
            continue;
        }
        std::uint32_t sid = 0;
        if (!validate_string_id(raw, table, sid)) return false;
        waiting_for_value = !waiting_for_value;
        if (!waiting_for_value) ++summary.tag_count;
    }
    if (waiting_for_value) return false;
    return summary.encoded_value_count == group.dense.keys_vals_count &&
           summary.node_segments == group.dense.node_count;
}

class DenseTagNodeCursor {
public:
    DenseTagNodeCursor(const GroupLayout& group, const StringTableView& table) noexcept
        : stream_(group.raw), table_(&table), remaining_nodes_(group.dense.node_count),
          implicit_all_tagless_(group.dense.keys_vals_count == 0) {}

    bool next_node(DenseTagRange& tags) noexcept {
        tags = DenseTagRange{};
        if (remaining_nodes_ == 0) return false;
        if (implicit_all_tagless_) {
            --remaining_nodes_;
            return true;
        }

        KeysValsCursor start = stream_;
        std::size_t pair_count = 0;
        bool waiting_for_value = false;
        for (;;) {
            std::uint64_t raw = 0;
            bool has_value = false;
            if (!stream_.next(raw, has_value) || !has_value) return false;
            if (raw == 0) {
                if (waiting_for_value) return false;
                break;
            }
            std::uint32_t sid = 0;
            if (!validate_string_id(raw, *table_, sid)) return false;
            waiting_for_value = !waiting_for_value;
            if (!waiting_for_value) ++pair_count;
        }

        if (!DenseTagRange::from_validated(start, *table_, pair_count, tags)) return false;
        --remaining_nodes_;
        return true;
    }

    bool finish() noexcept {
        if (remaining_nodes_ != 0) return false;
        if (implicit_all_tagless_) return true;
        std::uint64_t raw = 0;
        bool has_value = false;
        return stream_.next(raw, has_value) && !has_value;
    }

private:
    KeysValsCursor stream_;
    const StringTableView* table_;
    std::size_t remaining_nodes_;
    bool implicit_all_tagless_;
};

// The current D synthetic benchmark profiles deliberately omit DenseInfo. The
// production D path still constructs and advances an empty metadata cursor for
// every node. Keep the same per-node state transition here; metadata-bearing
// profiles will extend this reference before they are compared.
class EmptyDenseInfoNodeCursor {
public:
    explicit EmptyDenseInfoNodeCursor(std::size_t nodes) noexcept : remaining_(nodes) {}
    bool next_node() noexcept {
        if (remaining_ == 0) return false;
        --remaining_;
        return true;
    }
    bool finish() const noexcept { return remaining_ == 0; }
private:
    std::size_t remaining_;
};

struct DenseNodeView {
    std::int64_t id = 0;
    std::int64_t lat_nano = 0;
    std::int64_t lon_nano = 0;
    DenseTagRange tags;
};

struct DecodeSummary {
    std::size_t node_count = 0;
    std::size_t tag_count = 0;
};

struct CoordinateSink {
    std::uint64_t checksum = 0;
    std::size_t node_count = 0;
    void put_dense_node_scalars(std::int64_t id, std::int64_t lat_nano,
                                std::int64_t lon_nano) noexcept {
        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon_nano));
        ++node_count;
    }
    void put(DenseNodeView node) noexcept {
        put_dense_node_scalars(node.id, node.lat_nano, node.lon_nano);
    }
};

struct TagIdSink {
    std::uint64_t checksum = 0;
    std::size_t node_count = 0;
    std::size_t tag_count = 0;
    void put_dense_node_scalars(std::int64_t id, std::int64_t lat_nano,
                                std::int64_t lon_nano) noexcept {
        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon_nano));
        ++node_count;
    }
    void put(DenseNodeView& node) noexcept {
        checksum = mix(checksum, static_cast<std::uint64_t>(node.id));
        checksum = mix(checksum, static_cast<std::uint64_t>(node.lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(node.lon_nano));
        auto tags = node.tags;
        while (!tags.empty()) {
            const auto tag = tags.front();
            checksum = mix(checksum, tag.key_sid);
            checksum = mix(checksum, tag.value_sid);
            ++tag_count;
            tags.pop_front();
        }
        ++node_count;
    }
};

struct TagByteSink {
    std::uint64_t checksum = 0;
    std::size_t node_count = 0;
    std::size_t tag_count = 0;
    void put_dense_node_scalars(std::int64_t id, std::int64_t lat_nano,
                                std::int64_t lon_nano) noexcept {
        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon_nano));
        ++node_count;
    }
    void put(DenseNodeView& node) noexcept {
        checksum = mix(checksum, static_cast<std::uint64_t>(node.id));
        checksum = mix(checksum, static_cast<std::uint64_t>(node.lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(node.lon_nano));
        auto tags = node.tags;
        while (!tags.empty()) {
            const auto tag = tags.front();
            checksum = mix(checksum, tag.key_sid);
            checksum = mix(checksum, tag.value_sid);
            checksum = mix(checksum, tag.key.size());
            checksum = mix(checksum, tag.value.size());
            if (!tag.key.empty()) {
                checksum = mix(checksum, tag.key.front());
                checksum = mix(checksum, tag.key.back());
            }
            if (!tag.value.empty()) {
                checksum = mix(checksum, tag.value.front());
                checksum = mix(checksum, tag.value.back());
            }
            ++tag_count;
            tags.pop_front();
        }
        ++node_count;
    }
};

template <bool HasTags, typename Sink>
bool emit_dense_nodes(const BlockLayout& block, const GroupLayout& group,
                      const StringTableView& table,
                      const DenseTagValidationSummary& tag_validation,
                      Sink& sink, DecodeSummary& summary) noexcept {
    if constexpr (HasTags) {
        DenseTagNodeCursor tag_nodes(group, table);
        DenseColumnCursor ids(group.raw, 1);
        DenseColumnCursor lats(group.raw, 8);
        DenseColumnCursor lons(group.raw, 9);

        std::int64_t id = 0, lat = 0, lon = 0;
        for (std::size_t i = 0; i < group.dense.node_count; ++i) {
            std::int64_t id_delta = 0, lat_delta = 0, lon_delta = 0;
            bool has_id = false, has_lat = false, has_lon = false;
            if (!ids.next(id_delta, has_id) || !lats.next(lat_delta, has_lat) ||
                !lons.next(lon_delta, has_lon)) return false;
            if (!has_id || !has_lat || !has_lon) return false;

            std::int64_t next_id = 0, next_lat = 0, next_lon = 0;
            if (!checked_add(id, id_delta, next_id) ||
                !checked_add(lat, lat_delta, next_lat) ||
                !checked_add(lon, lon_delta, next_lon)) return false;
            id = next_id; lat = next_lat; lon = next_lon;

            std::int64_t lat_nano = 0, lon_nano = 0;
            const auto factor = static_cast<std::int64_t>(block.granularity);
            if (!checked_mul_add(block.lat_offset, factor, lat, lat_nano) ||
                !checked_mul_add(block.lon_offset, factor, lon, lon_nano)) return false;

            DenseTagRange tags;
            if (!tag_nodes.next_node(tags)) return false;
            summary.tag_count += tags.length();
            DenseNodeView node{id, lat_nano, lon_nano, tags};
            sink.put(node);
            ++summary.node_count;
        }

        std::int64_t extra = 0;
        bool has_extra = false;
        if (!ids.next(extra, has_extra) || has_extra) return false;
        if (!lats.next(extra, has_extra) || has_extra) return false;
        if (!lons.next(extra, has_extra) || has_extra) return false;
        if (!tag_nodes.finish()) return false;
        return summary.tag_count == tag_validation.tag_count;
    } else {
        DenseColumnCursor ids(group.raw, 1);
        DenseColumnCursor lats(group.raw, 8);
        DenseColumnCursor lons(group.raw, 9);

        std::int64_t id = 0, lat = 0, lon = 0;
        for (std::size_t i = 0; i < group.dense.node_count; ++i) {
            std::int64_t id_delta = 0, lat_delta = 0, lon_delta = 0;
            bool has_id = false, has_lat = false, has_lon = false;
            if (!ids.next(id_delta, has_id) || !lats.next(lat_delta, has_lat) ||
                !lons.next(lon_delta, has_lon)) return false;
            if (!has_id || !has_lat || !has_lon) return false;

            std::int64_t next_id = 0, next_lat = 0, next_lon = 0;
            if (!checked_add(id, id_delta, next_id) ||
                !checked_add(lat, lat_delta, next_lat) ||
                !checked_add(lon, lon_delta, next_lon)) return false;
            id = next_id; lat = next_lat; lon = next_lon;

            std::int64_t lat_nano = 0, lon_nano = 0;
            const auto factor = static_cast<std::int64_t>(block.granularity);
            if (!checked_mul_add(block.lat_offset, factor, lat, lat_nano) ||
                !checked_mul_add(block.lon_offset, factor, lon, lon_nano)) return false;

            if constexpr (requires {
                sink.put_dense_node_scalars(id, lat_nano, lon_nano);
            }) {
                sink.put_dense_node_scalars(id, lat_nano, lon_nano);
            } else {
                DenseNodeView node{id, lat_nano, lon_nano, DenseTagRange{}};
                sink.put(node);
            }
            ++summary.node_count;
        }

        std::int64_t extra = 0;
        bool has_extra = false;
        if (!ids.next(extra, has_extra) || has_extra) return false;
        if (!lats.next(extra, has_extra) || has_extra) return false;
        if (!lons.next(extra, has_extra) || has_extra) return false;
        return summary.tag_count == tag_validation.tag_count;
    }
}

template <typename Sink>
bool decode_dense_nodes(const BlockLayout& block, const GroupLayout& group,
                        const StringTableView& table, Sink& sink,
                        DecodeSummary& summary) noexcept {
    summary = DecodeSummary{};
    if (!group.has_dense_nodes()) return true;
    if (group.dense.id_count != group.dense.lat_count ||
        group.dense.id_count != group.dense.lon_count) return false;

    const auto factor = static_cast<std::int64_t>(block.granularity);
    std::int64_t ignored = 0;
    if (group.dense.has_lat_range) {
        if (!checked_mul_add(block.lat_offset, factor, group.dense.min_lat, ignored) ||
            !checked_mul_add(block.lat_offset, factor, group.dense.max_lat, ignored)) return false;
    }
    if (group.dense.has_lon_range) {
        if (!checked_mul_add(block.lon_offset, factor, group.dense.min_lon, ignored) ||
            !checked_mul_add(block.lon_offset, factor, group.dense.max_lon, ignored)) return false;
    }

    // Current comparison workloads carry no DenseInfo. Refuse accidental
    // asymmetric work until both reference implementations benchmark the same
    // DenseInfo profiles.
    if (group.dense.has_dense_info) return false;

    DenseTagValidationSummary tag_validation;
    if (!validate_dense_tags(group, table, tag_validation)) return false;

    if (tag_validation.tag_count != 0) {
        return emit_dense_nodes<true>(
            block, group, table, tag_validation, sink, summary);
    }
    return emit_dense_nodes<false>(
        block, group, table, tag_validation, sink, summary);
}

enum class WorkloadProfile { tagless, typical, rich, mixed };
enum class SinkPath { coordinates, tag_ids, tag_bytes };

struct DecodeRun {
    std::uint64_t checksum = 0;
    std::size_t node_count = 0;
    std::size_t tag_count = 0;
    bool ok = false;
};

struct TimingStats {
    std::int64_t minimum_ns = 0;
    std::int64_t p10_ns = 0;
    std::int64_t median_ns = 0;
    std::int64_t p90_ns = 0;
    std::int64_t maximum_ns = 0;
};

struct BenchResult {
    TimingStats timings;
    std::uint64_t checksum = 0;
    bool ok = false;
};

struct Workload {
    std::string name;
    std::vector<Byte> block_bytes;
    std::vector<StringRef> string_refs;
    BlockLayout block;
    GroupLayout group;
    StringTableView table;
    std::size_t node_count = 0;
    std::size_t tag_count = 0;
    std::uint64_t coordinate_checksum = 0;
    std::uint64_t tag_id_checksum = 0;
    std::uint64_t tag_byte_checksum = 0;
};

DecodeRun decode_coordinates(const Workload& workload) noexcept {
    CoordinateSink sink;
    DecodeSummary summary;
    const bool ok = decode_dense_nodes(workload.block, workload.group, workload.table, sink, summary);
    return DecodeRun{sink.checksum, summary.node_count, summary.tag_count,
                     ok && sink.node_count == summary.node_count};
}

DecodeRun decode_tag_ids(const Workload& workload) noexcept {
    TagIdSink sink;
    DecodeSummary summary;
    const bool ok = decode_dense_nodes(workload.block, workload.group, workload.table, sink, summary);
    return DecodeRun{sink.checksum, summary.node_count, summary.tag_count,
                     ok && sink.node_count == summary.node_count &&
                     sink.tag_count == summary.tag_count};
}

DecodeRun decode_tag_bytes(const Workload& workload) noexcept {
    TagByteSink sink;
    DecodeSummary summary;
    const bool ok = decode_dense_nodes(workload.block, workload.group, workload.table, sink, summary);
    return DecodeRun{sink.checksum, summary.node_count, summary.tag_count,
                     ok && sink.node_count == summary.node_count &&
                     sink.tag_count == summary.tag_count};
}

DecodeRun decode_selected(const Workload& workload, SinkPath path) noexcept {
    switch (path) {
        case SinkPath::coordinates: return decode_coordinates(workload);
        case SinkPath::tag_ids: return decode_tag_ids(workload);
        case SinkPath::tag_bytes: return decode_tag_bytes(workload);
    }
    return {};
}

std::uint64_t expected_checksum(const Workload& workload, SinkPath path) noexcept {
    switch (path) {
        case SinkPath::coordinates: return workload.coordinate_checksum;
        case SinkPath::tag_ids: return workload.tag_id_checksum;
        case SinkPath::tag_bytes: return workload.tag_byte_checksum;
    }
    return 0;
}

bool validate_run(const Workload& workload, SinkPath path, std::uint32_t iterations,
                  const DecodeRun& aggregate) noexcept {
    return aggregate.ok &&
           aggregate.node_count == workload.node_count * static_cast<std::size_t>(iterations) &&
           aggregate.tag_count == workload.tag_count * static_cast<std::size_t>(iterations) &&
           aggregate.checksum == expected_checksum(workload, path) * iterations;
}

bool warmup(const Workload& workload, SinkPath path, std::uint32_t iterations) noexcept {
    for (std::uint32_t i = 0; i < iterations; ++i) {
        const auto run = decode_selected(workload, path);
        if (!run.ok || run.node_count != workload.node_count ||
            run.tag_count != workload.tag_count ||
            run.checksum != expected_checksum(workload, path)) return false;
    }
    return true;
}

std::int64_t time_path(const Workload& workload, SinkPath path, std::uint32_t iterations,
                       std::uint64_t& observable_checksum) noexcept {
    const auto start = std::chrono::steady_clock::now();
    std::uint64_t aggregate_checksum = 0;
    std::size_t aggregate_nodes = 0;
    std::size_t aggregate_tags = 0;
    bool ok = true;
    for (std::uint32_t i = 0; i < iterations; ++i) {
        const auto run = decode_selected(workload, path);
        aggregate_checksum += run.checksum;
        aggregate_nodes += run.node_count;
        aggregate_tags += run.tag_count;
        ok = ok && run.ok;
    }
    const auto stop = std::chrono::steady_clock::now();
    observable_checksum = aggregate_checksum;
    const DecodeRun aggregate{aggregate_checksum, aggregate_nodes, aggregate_tags, ok};
    if (!validate_run(workload, path, iterations, aggregate)) return -1;
    return std::chrono::duration_cast<std::chrono::nanoseconds>(stop - start).count();
}

std::int64_t percentile(const std::vector<std::int64_t>& sorted, std::uint32_t percent) noexcept {
    if (sorted.empty()) return 0;
    const std::size_t numerator = (sorted.size() - 1) * percent + 50;
    return sorted[numerator / 100];
}

BenchResult summarize(std::vector<std::int64_t> timings, std::uint64_t checksum) {
    if (timings.empty()) return {};
    std::sort(timings.begin(), timings.end());
    return BenchResult{TimingStats{timings.front(), percentile(timings, 10),
                                   percentile(timings, 50), percentile(timings, 90),
                                   timings.back()}, checksum, true};
}

bool record_sample(const Workload& workload, SinkPath path, std::uint32_t iterations,
                   std::uint32_t sample,
                   std::vector<std::int64_t>& coordinate_timings,
                   std::vector<std::int64_t>& tag_id_timings,
                   std::vector<std::int64_t>& tag_byte_timings,
                   std::uint64_t& coordinate_checksum,
                   std::uint64_t& tag_id_checksum,
                   std::uint64_t& tag_byte_checksum) noexcept {
    std::uint64_t observed = 0;
    const auto elapsed = time_path(workload, path, iterations, observed);
    if (elapsed < 0) return false;
    switch (path) {
        case SinkPath::coordinates:
            coordinate_timings[sample] = elapsed;
            coordinate_checksum += observed ^ sample;
            break;
        case SinkPath::tag_ids:
            tag_id_timings[sample] = elapsed;
            tag_id_checksum += observed ^ sample;
            break;
        case SinkPath::tag_bytes:
            tag_byte_timings[sample] = elapsed;
            tag_byte_checksum += observed ^ sample;
            break;
    }
    return true;
}

bool measure_all(const Workload& workload, std::uint32_t iterations,
                 std::uint32_t samples, std::uint32_t warmup_iterations,
                 BenchResult& coordinates, BenchResult& tag_ids,
                 BenchResult& tag_bytes) {
    if (!warmup(workload, SinkPath::coordinates, warmup_iterations) ||
        !warmup(workload, SinkPath::tag_ids, warmup_iterations) ||
        !warmup(workload, SinkPath::tag_bytes, warmup_iterations)) return false;

    std::vector<std::int64_t> coordinate_timings(samples);
    std::vector<std::int64_t> tag_id_timings(samples);
    std::vector<std::int64_t> tag_byte_timings(samples);
    std::uint64_t coordinate_checksum = 0, tag_id_checksum = 0, tag_byte_checksum = 0;

    static constexpr std::array<std::array<SinkPath, 3>, 6> orders{{
        {SinkPath::coordinates, SinkPath::tag_ids, SinkPath::tag_bytes},
        {SinkPath::coordinates, SinkPath::tag_bytes, SinkPath::tag_ids},
        {SinkPath::tag_ids, SinkPath::coordinates, SinkPath::tag_bytes},
        {SinkPath::tag_ids, SinkPath::tag_bytes, SinkPath::coordinates},
        {SinkPath::tag_bytes, SinkPath::coordinates, SinkPath::tag_ids},
        {SinkPath::tag_bytes, SinkPath::tag_ids, SinkPath::coordinates},
    }};

    for (std::uint32_t sample = 0; sample < samples; ++sample) {
        const auto& order = orders[sample % orders.size()];
        for (const auto path : order) {
            if (!record_sample(workload, path, iterations, sample,
                               coordinate_timings, tag_id_timings, tag_byte_timings,
                               coordinate_checksum, tag_id_checksum, tag_byte_checksum)) return false;
        }
    }
    coordinates = summarize(std::move(coordinate_timings), coordinate_checksum);
    tag_ids = summarize(std::move(tag_id_timings), tag_id_checksum);
    tag_bytes = summarize(std::move(tag_byte_timings), tag_byte_checksum);
    return coordinates.ok && tag_ids.ok && tag_bytes.ok;
}

BenchResult measure_single(const Workload& workload, SinkPath path,
                           std::uint32_t iterations, std::uint32_t samples,
                           std::uint32_t warmup_iterations) {
    if (!warmup(workload, path, warmup_iterations)) return {};
    std::vector<std::int64_t> timings(samples);
    std::uint64_t observable_checksum = 0;
    for (std::uint32_t sample = 0; sample < samples; ++sample) {
        std::uint64_t observed = 0;
        const auto elapsed = time_path(workload, path, iterations, observed);
        if (elapsed < 0) return {};
        timings[sample] = elapsed;
        observable_checksum += observed ^ sample;
    }
    return summarize(std::move(timings), observable_checksum);
}

std::string_view path_name(SinkPath path) noexcept {
    switch (path) {
        case SinkPath::coordinates: return "coordinates";
        case SinkPath::tag_ids: return "tag-ids";
        case SinkPath::tag_bytes: return "tag-bytes";
    }
    return "unknown";
}

void report(SinkPath path, const Workload& workload, std::uint32_t iterations,
            const BenchResult& result) {
    const double total_nodes = static_cast<double>(workload.node_count) * iterations;
    const double total_group_bytes = static_cast<double>(workload.group.raw.size()) * iterations;
    const double median_seconds = static_cast<double>(result.timings.median_ns) / 1'000'000'000.0;
    const double median_ns_per_node = static_cast<double>(result.timings.median_ns) / total_nodes;
    const double p10_ns_per_node = static_cast<double>(result.timings.p10_ns) / total_nodes;
    const double p90_ns_per_node = static_cast<double>(result.timings.p90_ns) / total_nodes;
    const double min_ns_per_node = static_cast<double>(result.timings.minimum_ns) / total_nodes;
    const double max_ns_per_node = static_cast<double>(result.timings.maximum_ns) / total_nodes;
    const double mega_nodes_per_second = total_nodes / median_seconds / 1'000'000.0;
    const double mebi_group_bytes_per_second = total_group_bytes / median_seconds / (1024.0 * 1024.0);
    const double spread_percent = result.timings.median_ns == 0 ? 0.0 :
        static_cast<double>(result.timings.p90_ns - result.timings.p10_ns) /
        result.timings.median_ns * 100.0;

    std::printf("%-9s %-12s p50=%8.3f ns/node %7.2f Mnode/s %8.2f MiB/s(group)  "
                "p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016llx\n",
                workload.name.c_str(), std::string(path_name(path)).c_str(),
                median_ns_per_node, mega_nodes_per_second, mebi_group_bytes_per_second,
                p10_ns_per_node, p90_ns_per_node, spread_percent,
                min_ns_per_node, max_ns_per_node,
                static_cast<unsigned long long>(result.checksum));
}

bool parse_profile(std::string_view name, WorkloadProfile& profile) noexcept {
    if (name == "tagless") { profile = WorkloadProfile::tagless; return true; }
    if (name == "typical") { profile = WorkloadProfile::typical; return true; }
    if (name == "rich") { profile = WorkloadProfile::rich; return true; }
    if (name == "mixed") { profile = WorkloadProfile::mixed; return true; }
    return false;
}

bool parse_path(std::string_view name, SinkPath& path) noexcept {
    if (name == "coordinates" || name == "coords") { path = SinkPath::coordinates; return true; }
    if (name == "tag-ids" || name == "tags") { path = SinkPath::tag_ids; return true; }
    if (name == "tag-bytes" || name == "strings") { path = SinkPath::tag_bytes; return true; }
    return false;
}

std::string_view profile_name(WorkloadProfile profile) noexcept {
    switch (profile) {
        case WorkloadProfile::tagless: return "tagless";
        case WorkloadProfile::typical: return "typical";
        case WorkloadProfile::rich: return "rich";
        case WorkloadProfile::mixed: return "mixed";
    }
    return "unknown";
}

std::size_t tag_count_for_node(WorkloadProfile profile, std::size_t node_index) noexcept {
    switch (profile) {
        case WorkloadProfile::tagless: return 0;
        case WorkloadProfile::typical: return 2;
        case WorkloadProfile::rich: return 8;
        case WorkloadProfile::mixed:
            switch (node_index & 7U) {
                case 0: return 0; case 1: return 1; case 2: return 2; case 3: return 3;
                case 4: return 0; case 5: return 2; case 6: return 4; case 7: return 1;
            }
    }
    return 0;
}

std::int64_t latitude_delta(std::size_t node_index) noexcept {
    static constexpr std::array<std::int64_t, 8> values{1, 0, -1, 2, -2, 1, 0, 1};
    return values[node_index & 7U];
}

std::int64_t longitude_delta(std::size_t node_index) noexcept {
    static constexpr std::array<std::int64_t, 8> values{-1, 1, 0, 1, 2, -1, -2, 0};
    return values[node_index & 7U];
}

std::uint64_t zigzag64(std::int64_t value) noexcept {
    return (static_cast<std::uint64_t>(value) << 1) ^
           static_cast<std::uint64_t>(value >> 63);
}

void append_varint(std::vector<Byte>& output, std::uint64_t value) {
    while (value >= 0x80) {
        output.push_back(static_cast<Byte>((value & 0x7fU) | 0x80U));
        value >>= 7;
    }
    output.push_back(static_cast<Byte>(value));
}

void append_field_key(std::vector<Byte>& output, std::uint32_t field_number,
                      std::uint32_t wire_type) {
    append_varint(output, (static_cast<std::uint64_t>(field_number) << 3) | wire_type);
}

void append_length_delimited(std::vector<Byte>& output, std::uint32_t field_number,
                             Bytes payload) {
    append_field_key(output, field_number, 2);
    append_varint(output, payload.size());
    output.insert(output.end(), payload.begin(), payload.end());
}

void append_string(std::vector<Byte>& string_table, std::string_view value) {
    const auto* bytes = reinterpret_cast<const Byte*>(value.data());
    append_length_delimited(string_table, 1, Bytes(bytes, value.size()));
}

bool build_string_table_view(Workload& workload, Bytes string_table) {
    workload.string_refs.clear();
    Cursor cursor(string_table);
    const Byte* block_begin = workload.block_bytes.data();
    while (!cursor.empty()) {
        FieldHeader field;
        if (!read_field_header(cursor, field)) return false;
        if (field.number == 1 && field.wire == 2) {
            Bytes value;
            if (!read_length_delimited(cursor, value)) return false;
            const auto offset = static_cast<std::size_t>(value.data() - block_begin);
            if (offset > std::numeric_limits<std::uint32_t>::max() ||
                value.size() > std::numeric_limits<std::uint32_t>::max()) return false;
            workload.string_refs.push_back(StringRef{static_cast<std::uint32_t>(offset),
                                                     static_cast<std::uint32_t>(value.size())});
            continue;
        }
        if (!skip_field_value(cursor, field)) return false;
    }
    workload.table = StringTableView{workload.block_bytes.data(), workload.string_refs};
    return !workload.string_refs.empty() && workload.string_refs.front().length == 0;
}

bool decode_block_scaffolding(Workload& workload) {
    Cursor cursor(Bytes(workload.block_bytes.data(), workload.block_bytes.size()));
    Bytes string_table;
    Bytes group;
    while (!cursor.empty()) {
        FieldHeader field;
        if (!read_field_header(cursor, field)) return false;
        if (field.number == 1 && field.wire == 2) {
            if (!read_length_delimited(cursor, string_table)) return false;
            continue;
        }
        if (field.number == 2 && field.wire == 2) {
            if (!read_length_delimited(cursor, group)) return false;
            continue;
        }
        if (!skip_field_value(cursor, field)) return false;
    }
    if (string_table.empty() || group.empty()) return false;
    if (!build_string_table_view(workload, string_table)) return false;
    return decode_group_layout(group, workload.group);
}

bool build_workload(WorkloadProfile profile, std::size_t node_count, Workload& workload) {
    workload = Workload{};
    workload.name = std::string(profile_name(profile));
    workload.node_count = node_count;

    static constexpr std::array<std::string_view, 17> strings{
        "", "highway", "residential", "name", "Main Street", "surface", "asphalt",
        "lit", "yes", "maxspeed", "50", "lanes", "2", "access", "destination",
        "source", "survey"
    };

    std::vector<Byte> string_table;
    for (const auto value : strings) append_string(string_table, value);

    std::vector<Byte> ids, lats, lons, keys_vals;
    std::size_t total_tags = 0;
    ids.reserve(node_count);
    lats.reserve(node_count);
    lons.reserve(node_count);
    if (profile != WorkloadProfile::tagless) keys_vals.reserve(node_count * 5);

    for (std::size_t i = 0; i < node_count; ++i) {
        append_varint(ids, zigzag64(1));
        append_varint(lats, zigzag64(latitude_delta(i)));
        append_varint(lons, zigzag64(longitude_delta(i)));

        const auto tags = tag_count_for_node(profile, i);
        total_tags += tags;
        if (profile != WorkloadProfile::tagless) {
            for (std::size_t tag_index = 0; tag_index < tags; ++tag_index) {
                const auto pair = (i + tag_index) & 7U;
                const auto key_sid = 1U + static_cast<std::uint32_t>(pair * 2U);
                const auto value_sid = key_sid + 1U;
                append_varint(keys_vals, key_sid);
                append_varint(keys_vals, value_sid);
            }
            append_varint(keys_vals, 0);
        }
    }
    workload.tag_count = total_tags;

    std::vector<Byte> dense;
    append_length_delimited(dense, 1, Bytes(ids.data(), ids.size()));
    append_length_delimited(dense, 8, Bytes(lats.data(), lats.size()));
    append_length_delimited(dense, 9, Bytes(lons.data(), lons.size()));
    if (profile != WorkloadProfile::tagless) {
        append_length_delimited(dense, 10, Bytes(keys_vals.data(), keys_vals.size()));
    }

    std::vector<Byte> group;
    append_length_delimited(group, 2, Bytes(dense.data(), dense.size()));

    std::vector<Byte> block;
    append_length_delimited(block, 1, Bytes(string_table.data(), string_table.size()));
    append_length_delimited(block, 2, Bytes(group.data(), group.size()));
    workload.block_bytes = std::move(block);

    if (!decode_block_scaffolding(workload)) return false;
    if (workload.group.dense.node_count != node_count ||
        workload.group.dense.has_dense_info) return false;

    const auto coordinates = decode_coordinates(workload);
    const auto tag_ids = decode_tag_ids(workload);
    const auto tag_bytes = decode_tag_bytes(workload);
    if (!coordinates.ok || !tag_ids.ok || !tag_bytes.ok ||
        coordinates.node_count != node_count || coordinates.tag_count != total_tags ||
        tag_ids.node_count != node_count || tag_ids.tag_count != total_tags ||
        tag_bytes.node_count != node_count || tag_bytes.tag_count != total_tags) return false;

    workload.coordinate_checksum = coordinates.checksum;
    workload.tag_id_checksum = tag_ids.checksum;
    workload.tag_byte_checksum = tag_bytes.checksum;
    return true;
}

bool run_workload(const Workload& workload, bool all_paths, SinkPath selected_path,
                  std::uint32_t iterations, std::uint32_t samples,
                  std::uint32_t warmup_iterations) {
    std::printf("profile=%s nodes=%zu tags=%zu tags/node=%.3f group-bytes=%zu\n",
                workload.name.c_str(), workload.node_count, workload.tag_count,
                workload.node_count == 0 ? 0.0 :
                    static_cast<double>(workload.tag_count) / workload.node_count,
                workload.group.raw.size());

    if (all_paths) {
        BenchResult coordinates, tag_ids, tag_bytes;
        if (!measure_all(workload, iterations, samples, warmup_iterations,
                         coordinates, tag_ids, tag_bytes)) return false;
        report(SinkPath::coordinates, workload, iterations, coordinates);
        report(SinkPath::tag_ids, workload, iterations, tag_ids);
        report(SinkPath::tag_bytes, workload, iterations, tag_bytes);
        return true;
    }
    const auto result = measure_single(workload, selected_path, iterations, samples, warmup_iterations);
    if (!result.ok) return false;
    report(selected_path, workload, iterations, result);
    return true;
}

bool parse_unsigned(std::string_view text, std::uint64_t& value) noexcept {
    const auto first = text.data();
    const auto last = text.data() + text.size();
    const auto result = std::from_chars(first, last, value);
    return result.ec == std::errc{} && result.ptr == last;
}

bool option_value(int& i, int argc, char** argv, std::string_view arg,
                  std::string_view name, std::string_view& value) noexcept {
    const std::string prefix = std::string(name) + "=";
    if (arg.starts_with(prefix)) {
        value = arg.substr(prefix.size());
        return true;
    }
    if (arg == name && i + 1 < argc) {
        value = argv[++i];
        return true;
    }
    return false;
}

void print_help() {
    std::cout
        << "d-osm DenseNodes C++ semantic-reference benchmark\n"
        << "  --nodes=N\n"
        << "  --iterations=N\n"
        << "  --samples=N\n"
        << "  --warmup=N\n"
        << "  --profile=all|tagless|typical|rich|mixed\n"
        << "  --path=all|coordinates|tag-ids|tag-bytes\n";
}

std::string compiler_name() {
#if defined(__clang__)
    return std::string("Clang ") + __clang_version__;
#elif defined(__GNUC__)
    return std::string("GCC ") + __VERSION__;
#else
    return "unknown C++ compiler";
#endif
}

} // namespace

int main(int argc, char** argv) {
    std::size_t node_count = 200'000;
    std::uint32_t iterations = 5;
    std::uint32_t samples = 30;
    std::uint32_t warmup_iterations = 2;
    std::string selected_profile = "all";
    std::string selected_path_name = "all";

    for (int i = 1; i < argc; ++i) {
        const std::string_view arg = argv[i];
        if (arg == "--help" || arg == "-h") {
            print_help();
            return 0;
        }
        std::string_view value;
        std::uint64_t parsed = 0;
        if (option_value(i, argc, argv, arg, "--nodes", value)) {
            if (!parse_unsigned(value, parsed)) return 2;
            node_count = static_cast<std::size_t>(parsed);
            continue;
        }
        if (option_value(i, argc, argv, arg, "--iterations", value)) {
            if (!parse_unsigned(value, parsed) || parsed > std::numeric_limits<std::uint32_t>::max()) return 2;
            iterations = static_cast<std::uint32_t>(parsed);
            continue;
        }
        if (option_value(i, argc, argv, arg, "--samples", value)) {
            if (!parse_unsigned(value, parsed) || parsed > std::numeric_limits<std::uint32_t>::max()) return 2;
            samples = static_cast<std::uint32_t>(parsed);
            continue;
        }
        if (option_value(i, argc, argv, arg, "--warmup", value)) {
            if (!parse_unsigned(value, parsed) || parsed > std::numeric_limits<std::uint32_t>::max()) return 2;
            warmup_iterations = static_cast<std::uint32_t>(parsed);
            continue;
        }
        if (option_value(i, argc, argv, arg, "--profile", value)) {
            selected_profile = std::string(value);
            continue;
        }
        if (option_value(i, argc, argv, arg, "--path", value)) {
            selected_path_name = std::string(value);
            continue;
        }
        std::cerr << "unknown argument: " << arg << '\n';
        return 2;
    }

    if (node_count == 0 || iterations == 0 || samples == 0 || samples > 100'000) {
        std::cerr << "nodes, iterations and samples must be valid non-zero values\n";
        return 2;
    }

    const bool all_paths = selected_path_name == "all";
    SinkPath selected_path = SinkPath::coordinates;
    if (!all_paths && !parse_path(selected_path_name, selected_path)) {
        std::cerr << "unknown path: " << selected_path_name << '\n';
        return 2;
    }

    std::cout << "d-osm DenseNodes C++ semantic-reference benchmark\n";
    std::cout << "compiler: " << compiler_name() << '\n';
    std::cout << "nodes/profile: " << node_count
              << "  iterations/sample: " << iterations
              << "  samples: " << samples
              << "  warmup: " << warmup_iterations << '\n';
    if (all_paths) {
        std::cout << "ordering: rotating all six permutations of the three sink paths\n";
    } else {
        std::cout << "ordering: single path (" << selected_path_name << ")\n";
    }
    std::cout << "statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50\n";
    std::cout << "timed: semantic-reference DenseNodes preflight + emission + selected sink work\n";
    std::cout << "excluded: workload generation, block/group layout, StringTable indexing, validation, sorting and reporting\n";
    std::cout << "comparison contract: no DenseInfo; full tag preflight; checked deltas/coordinates; identical sink checksum\n";
    std::cout << "MiB/s(group) is serialized PrimitiveGroup memory throughput, not compressed PBF I/O\n\n";

    static constexpr std::array<WorkloadProfile, 4> all_profiles{
        WorkloadProfile::tagless, WorkloadProfile::typical,
        WorkloadProfile::rich, WorkloadProfile::mixed
    };

    auto run_profile = [&](WorkloadProfile profile) -> bool {
        Workload workload;
        if (!build_workload(profile, node_count, workload)) {
            std::cerr << "failed to build/validate profile: " << profile_name(profile) << '\n';
            return false;
        }
        if (!run_workload(workload, all_paths, selected_path,
                          iterations, samples, warmup_iterations)) {
            std::cerr << "benchmark consistency failure: " << workload.name << '\n';
            return false;
        }
        std::cout << '\n';
        return true;
    };

    if (selected_profile == "all") {
        for (const auto profile : all_profiles) {
            if (!run_profile(profile)) return 3;
        }
        return 0;
    }

    WorkloadProfile profile;
    if (!parse_profile(selected_profile, profile)) {
        std::cerr << "unknown profile: " << selected_profile << '\n';
        return 2;
    }
    return run_profile(profile) ? 0 : 3;
}
