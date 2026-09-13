// Diagnostic C++ reference for d-osm DenseNodes one-byte varint core.
// Copyright © 2026 Alexander Bernardi. MIT License.

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string_view>
#include <vector>

namespace {

enum class Stage : std::size_t {
    index_signed,
    pointer_signed,
    cursor_byte_signed,
    cursor_varint,
    cursor_svarint,
};

struct Workload {
    std::vector<std::uint8_t> ids;
    std::vector<std::uint8_t> lats;
    std::vector<std::uint8_t> lons;
    std::size_t node_count{};
};

struct Cursor {
    const std::uint8_t* ptr{};
    std::size_t remaining{};

    explicit Cursor(const std::vector<std::uint8_t>& bytes)
        : ptr(bytes.data()), remaining(bytes.size()) {}

    inline bool read_byte(std::uint8_t& out) noexcept {
        if (remaining == 0) {
            out = 0;
            return false;
        }
        out = *ptr++;
        --remaining;
        return true;
    }

    bool empty() const noexcept { return remaining == 0; }
};

struct Run { std::uint64_t checksum{}; bool ok{}; };
struct Stats { double min{}, p10{}, p50{}, p90{}, max{}; };

// Equivalent, branch-free protobuf ZigZag expression; split out so the
// compiler sees the same operation in all signed stages.
inline std::int64_t zigzag(std::uint64_t value) noexcept {
    return static_cast<std::int64_t>(value >> 1) ^
        -static_cast<std::int64_t>(value & 1U);
}

inline std::uint64_t finish_checksum(
    std::uint64_t a, std::uint64_t b, std::uint64_t c) noexcept {
    std::uint64_t state = UINT64_C(0xcbf29ce484222325);
    state = (state ^ a) * UINT64_C(0x00000100000001b3);
    state = (state ^ b) * UINT64_C(0x00000100000001b3);
    state = (state ^ c) * UINT64_C(0x00000100000001b3);
    return state;
}

std::int64_t lat_delta(std::size_t i) noexcept {
    static constexpr std::int64_t v[8] = {1, 0, -1, 2, -2, 1, 0, 1};
    return v[i & 7];
}

std::int64_t lon_delta(std::size_t i) noexcept {
    static constexpr std::int64_t v[8] = {-1, 1, 0, 1, 2, -1, -2, 0};
    return v[i & 7];
}

std::uint64_t encode_zigzag64(std::int64_t value) noexcept {
    return (static_cast<std::uint64_t>(value) << 1) ^
        static_cast<std::uint64_t>(value >> 63);
}

void append_varint(std::vector<std::uint8_t>& out, std::uint64_t value) {
    while (value >= 0x80) {
        out.push_back(static_cast<std::uint8_t>((value & 0x7f) | 0x80));
        value >>= 7;
    }
    out.push_back(static_cast<std::uint8_t>(value));
}

Workload build_workload(std::size_t count) {
    Workload w;
    w.node_count = count;
    w.ids.reserve(count);
    w.lats.reserve(count);
    w.lons.reserve(count);
    for (std::size_t i = 0; i < count; ++i) {
        append_varint(w.ids, encode_zigzag64(1));
        append_varint(w.lats, encode_zigzag64(lat_delta(i)));
        append_varint(w.lons, encode_zigzag64(lon_delta(i)));
    }
    return w;
}

inline bool read_varint64(Cursor& c, std::uint64_t& value) noexcept {
    std::uint8_t first;
    if (!c.read_byte(first)) return false;
    if ((first & 0x80) == 0) {
        value = first;
        return true;
    }
    std::uint64_t result = first & 0x7fU;
    unsigned shift = 7;
    for (unsigned i = 1; i < 9; ++i) {
        std::uint8_t b;
        if (!c.read_byte(b)) return false;
        result |= static_cast<std::uint64_t>(b & 0x7fU) << shift;
        if ((b & 0x80) == 0) {
            value = result;
            return true;
        }
        shift += 7;
    }
    std::uint8_t last;
    if (!c.read_byte(last) || last > 1) return false;
    value = result | (static_cast<std::uint64_t>(last) << 63);
    return true;
}

inline bool read_svarint64(Cursor& c, std::int64_t& value) noexcept {
    std::uint64_t encoded;
    if (!read_varint64(c, encoded)) return false;
    value = zigzag(encoded);
    return true;
}

Run run_index_signed(const Workload& w) noexcept {
    if (w.ids.size() != w.node_count || w.lats.size() != w.node_count || w.lons.size() != w.node_count)
        return {};
    std::uint64_t a = 0, b = 0, c = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        a += static_cast<std::uint64_t>(zigzag(w.ids[i]));
        b += static_cast<std::uint64_t>(zigzag(w.lats[i]));
        c += static_cast<std::uint64_t>(zigzag(w.lons[i]));
    }
    return {finish_checksum(a, b, c), true};
}

Run run_pointer_signed(const Workload& w) noexcept {
    if (w.ids.size() != w.node_count || w.lats.size() != w.node_count || w.lons.size() != w.node_count)
        return {};
    auto ids = w.ids.data();
    auto lats = w.lats.data();
    auto lons = w.lons.data();
    std::uint64_t a = 0, b = 0, c = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        a += static_cast<std::uint64_t>(zigzag(*ids++));
        b += static_cast<std::uint64_t>(zigzag(*lats++));
        c += static_cast<std::uint64_t>(zigzag(*lons++));
    }
    return {finish_checksum(a, b, c), true};
}

Run run_cursor_byte_signed(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::uint64_t a = 0, b = 0, c = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::uint8_t id, lat, lon;
        if (!ids.read_byte(id) || !lats.read_byte(lat) || !lons.read_byte(lon)) return {};
        a += static_cast<std::uint64_t>(zigzag(id));
        b += static_cast<std::uint64_t>(zigzag(lat));
        c += static_cast<std::uint64_t>(zigzag(lon));
    }
    return {finish_checksum(a, b, c), ids.empty() && lats.empty() && lons.empty()};
}

Run run_cursor_varint(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::uint64_t a = 0, b = 0, c = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::uint64_t id, lat, lon;
        if (!read_varint64(ids, id) || !read_varint64(lats, lat) || !read_varint64(lons, lon)) return {};
        a += id; b += lat; c += lon;
    }
    return {finish_checksum(a, b, c), ids.empty() && lats.empty() && lons.empty()};
}

Run run_cursor_svarint(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::uint64_t a = 0, b = 0, c = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t id, lat, lon;
        if (!read_svarint64(ids, id) || !read_svarint64(lats, lat) || !read_svarint64(lons, lon)) return {};
        a += static_cast<std::uint64_t>(id);
        b += static_cast<std::uint64_t>(lat);
        c += static_cast<std::uint64_t>(lon);
    }
    return {finish_checksum(a, b, c), ids.empty() && lats.empty() && lons.empty()};
}

Run run_stage(const Workload& w, Stage s) noexcept {
    switch (s) {
        case Stage::index_signed: return run_index_signed(w);
        case Stage::pointer_signed: return run_pointer_signed(w);
        case Stage::cursor_byte_signed: return run_cursor_byte_signed(w);
        case Stage::cursor_varint: return run_cursor_varint(w);
        case Stage::cursor_svarint: return run_cursor_svarint(w);
    }
    return {};
}

const char* stage_name(Stage s) noexcept {
    switch (s) {
        case Stage::index_signed: return "index-signed";
        case Stage::pointer_signed: return "pointer-signed";
        case Stage::cursor_byte_signed: return "cursor-byte";
        case Stage::cursor_varint: return "cursor-varint";
        case Stage::cursor_svarint: return "cursor-svarint";
    }
    return "?";
}

std::size_t percentile_index(std::size_t n, std::size_t numerator, std::size_t denominator) {
    return n <= 1 ? 0 : ((n - 1) * numerator) / denominator;
}

Stats summarize(std::vector<double> samples) {
    std::sort(samples.begin(), samples.end());
    return {
        samples.front(),
        samples[percentile_index(samples.size(), 1, 10)],
        samples[percentile_index(samples.size(), 1, 2)],
        samples[percentile_index(samples.size(), 9, 10)],
        samples.back(),
    };
}

bool parse_size(std::string_view arg, std::string_view prefix, std::size_t& out) {
    if (!arg.starts_with(prefix)) return false;
    out = static_cast<std::size_t>(std::strtoull(arg.data() + prefix.size(), nullptr, 10));
    return true;
}

} // namespace

int main(int argc, char** argv) {
    std::size_t nodes = 1'000'000;
    std::size_t samples = 30;
    std::size_t warmup = 2;
    std::size_t iterations = 1;
    for (int i = 1; i < argc; ++i) {
        std::string_view a(argv[i]);
        if (parse_size(a, "--nodes=", nodes) || parse_size(a, "--samples=", samples) ||
            parse_size(a, "--warmup=", warmup) || parse_size(a, "--iterations=", iterations)) continue;
        std::fprintf(stderr, "unknown argument: %s\n", argv[i]);
        return 2;
    }
    if (nodes == 0 || samples == 0 || iterations != 1) {
        std::fprintf(stderr, "nodes and samples must be > 0; iterations must be exactly 1\n");
        return 2;
    }

    auto workload = build_workload(nodes);
    constexpr std::array<Stage, 5> stages = {
        Stage::index_signed, Stage::pointer_signed, Stage::cursor_byte_signed,
        Stage::cursor_varint, Stage::cursor_svarint,
    };
    std::array<std::uint64_t, 5> expected{};
    for (std::size_t i = 0; i < stages.size(); ++i) {
        auto r = run_stage(workload, stages[i]);
        if (!r.ok) return 3;
        expected[i] = r.checksum;
    }
    if (expected[0] != expected[1] || expected[0] != expected[2] || expected[0] != expected[4]) {
        std::fprintf(stderr, "signed stage checksum mismatch\n");
        return 3;
    }

#if defined(__clang__)
    std::printf("d-osm DenseNodes C++ one-byte varint-core benchmark\ncompiler: Clang %s\n", __clang_version__);
#elif defined(__GNUC__)
    std::printf("d-osm DenseNodes C++ one-byte varint-core benchmark\ncompiler: GCC %s\n", __VERSION__);
#else
    std::printf("d-osm DenseNodes C++ one-byte varint-core benchmark\n");
#endif
    std::printf("nodes: %zu  values: %zu  samples: %zu  warmup: %zu\n", nodes, nodes * 3, samples, warmup);
    std::printf("packed bytes: ids=%zu lats=%zu lons=%zu total=%zu\n",
        workload.ids.size(), workload.lats.size(), workload.lons.size(),
        workload.ids.size() + workload.lats.size() + workload.lons.size());
    std::printf("all generated sint64 values use exactly one protobuf varint byte\n");
    std::printf("one complete stage run per timed sample; repeated pure iterations are forbidden\n");
    std::printf("ordering: rotating five cyclic stage orders\n");
    std::printf("statistics: min, p10, p50, p90, max; delta80=(p90-p10)/p50\n\n");

    for (std::size_t i = 0; i < stages.size(); ++i) {
        for (std::size_t j = 0; j < warmup; ++j) {
            auto r = run_stage(workload, stages[i]);
            if (!r.ok || r.checksum != expected[i]) return 3;
        }
    }

    constexpr std::array<std::array<Stage, 5>, 5> orders = {{
        {Stage::index_signed, Stage::pointer_signed, Stage::cursor_byte_signed, Stage::cursor_varint, Stage::cursor_svarint},
        {Stage::pointer_signed, Stage::cursor_byte_signed, Stage::cursor_varint, Stage::cursor_svarint, Stage::index_signed},
        {Stage::cursor_byte_signed, Stage::cursor_varint, Stage::cursor_svarint, Stage::index_signed, Stage::pointer_signed},
        {Stage::cursor_varint, Stage::cursor_svarint, Stage::index_signed, Stage::pointer_signed, Stage::cursor_byte_signed},
        {Stage::cursor_svarint, Stage::index_signed, Stage::pointer_signed, Stage::cursor_byte_signed, Stage::cursor_varint},
    }};

    std::array<std::vector<double>, 5> times;
    for (auto& v : times) v.resize(samples);

    for (std::size_t sample = 0; sample < samples; ++sample) {
        for (Stage stage : orders[sample % orders.size()]) {
            auto index = static_cast<std::size_t>(stage);
            auto start = std::chrono::steady_clock::now();
            auto r = run_stage(workload, stage);
            auto end = std::chrono::steady_clock::now();
            if (!r.ok || r.checksum != expected[index]) return 3;
            auto ns = std::chrono::duration<double, std::nano>(end - start).count();
            times[index][sample] = ns / static_cast<double>(nodes);
        }
    }

    for (std::size_t i = 0; i < stages.size(); ++i) {
        auto s = summarize(times[i]);
        double delta80 = s.p50 == 0.0 ? 0.0 : (s.p90 - s.p10) / s.p50 * 100.0;
        double mnode = s.p50 == 0.0 ? 0.0 : 1000.0 / s.p50;
        std::printf("%-14s p50=%8.3f ns/node (%6.3f ns/value) %7.2f Mnode/s  p10=%8.3f p90=%8.3f delta80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016llx\n",
            stage_name(stages[i]), s.p50, s.p50 / 3.0, mnode,
            s.p10, s.p90, delta80, s.min, s.max,
            static_cast<unsigned long long>(expected[i]));
    }
    return 0;
}
