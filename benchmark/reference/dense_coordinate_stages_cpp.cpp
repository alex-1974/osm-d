// Diagnostic C++ reference for d-osm DenseNodes coordinate-core stages.
// Copyright © 2026 Alexander Bernardi. MIT License.

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <string_view>
#include <vector>

namespace {

enum class Stage {
    sint64Decode,
    deltaUnchecked,
    deltaChecked,
    coordinatesUnchecked,
    coordinatesChecked
};

struct Workload {
    std::vector<std::uint8_t> ids;
    std::vector<std::uint8_t> lats;
    std::vector<std::uint8_t> lons;
    std::size_t node_count{};
    std::int32_t granularity{100};
    std::int64_t lat_offset{};
    std::int64_t lon_offset{};
};

struct Cursor {
    const std::uint8_t* ptr{};
    std::size_t remaining{};

    explicit Cursor(const std::vector<std::uint8_t>& bytes)
        : ptr(bytes.data()), remaining(bytes.size()) {}

    bool read_byte(std::uint8_t& out) noexcept {
        if (remaining == 0) return false;
        out = *ptr++;
        --remaining;
        return true;
    }
    bool empty() const noexcept { return remaining == 0; }
};

struct Run { std::uint64_t checksum{}; bool ok{}; };
struct Stats { double min{}, p10{}, p50{}, p90{}, max{}; };

inline std::uint64_t mix(std::uint64_t state, std::uint64_t value) noexcept {
    return state ^ (value + UINT64_C(0x9e3779b97f4a7c15) + (state << 6) + (state >> 2));
}

std::int64_t lat_delta(std::size_t i) noexcept {
    static constexpr std::int64_t v[8] = {1, 0, -1, 2, -2, 1, 0, 1};
    return v[i & 7];
}
std::int64_t lon_delta(std::size_t i) noexcept {
    static constexpr std::int64_t v[8] = {-1, 1, 0, 1, 2, -1, -2, 0};
    return v[i & 7];
}

std::uint64_t zigzag64(std::int64_t value) noexcept {
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
        append_varint(w.ids, zigzag64(1));
        append_varint(w.lats, zigzag64(lat_delta(i)));
        append_varint(w.lons, zigzag64(lon_delta(i)));
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
    value = static_cast<std::int64_t>(encoded >> 1) ^
        -static_cast<std::int64_t>(encoded & 1U);
    return true;
}

inline bool read_triple(
    Cursor& ids, Cursor& lats, Cursor& lons,
    std::int64_t& id, std::int64_t& lat, std::int64_t& lon) noexcept {
    return read_svarint64(ids, id) && read_svarint64(lats, lat) && read_svarint64(lons, lon);
}

inline bool checked_add(std::int64_t a, std::int64_t b, std::int64_t& out) noexcept {
    if (b > 0 && a > std::numeric_limits<std::int64_t>::max() - b) return false;
    if (b < 0 && a < std::numeric_limits<std::int64_t>::min() - b) return false;
    out = a + b;
    return true;
}

inline bool checked_mul(std::int64_t a, std::int64_t b, std::int64_t& out) noexcept {
    if (a == 0 || b == 0) { out = 0; return true; }
    const auto mn = std::numeric_limits<std::int64_t>::min();
    const auto mx = std::numeric_limits<std::int64_t>::max();
    if ((a == mn && b == -1) || (b == mn && a == -1)) return false;
    if (a > 0) {
        if (b > 0) { if (a > mx / b) return false; }
        else { if (b < mn / a) return false; }
    } else {
        if (b > 0) { if (a < mn / b) return false; }
        else { if (a < mx / b) return false; }
    }
    out = a * b;
    return true;
}

inline bool checked_mul_add(
    std::int64_t base, std::int64_t factor, std::int64_t value, std::int64_t& out) noexcept {
    std::int64_t product;
    return checked_mul(factor, value, product) && checked_add(base, product, out);
}

Run run_sint64_decode(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::uint64_t checksum = 0;
    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t a, b, c;
        if (!read_triple(ids, lats, lons, a, b, c)) return {};
        checksum = mix(checksum, static_cast<std::uint64_t>(a));
        checksum = mix(checksum, static_cast<std::uint64_t>(b));
        checksum = mix(checksum, static_cast<std::uint64_t>(c));
    }
    return {checksum, ids.empty() && lats.empty() && lons.empty()};
}

Run run_delta_unchecked(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::int64_t id = 0, lat = 0, lon = 0;
    std::uint64_t checksum = 0;

    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t di, da, dn;
        if (!read_triple(ids, lats, lons, di, da, dn)) return {};

        // The synthetic workload is deliberately far from integer overflow.
        id += di;
        lat += da;
        lon += dn;

        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon));
    }

    return {checksum, ids.empty() && lats.empty() && lons.empty()};
}

Run run_delta_checked(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::int64_t id = 0, lat = 0, lon = 0;
    std::uint64_t checksum = 0;

    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t di, da, dn;
        if (!read_triple(ids, lats, lons, di, da, dn)) return {};

        std::int64_t ni, na, nn;
        if (!checked_add(id, di, ni) ||
            !checked_add(lat, da, na) ||
            !checked_add(lon, dn, nn))
            return {};

        id = ni;
        lat = na;
        lon = nn;

        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon));
    }

    return {checksum, ids.empty() && lats.empty() && lons.empty()};
}

Run run_coordinates_unchecked(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::int64_t id = 0, lat = 0, lon = 0;
    std::uint64_t checksum = 0;
    const auto factor = static_cast<std::int64_t>(w.granularity);

    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t di, da, dn;
        if (!read_triple(ids, lats, lons, di, da, dn)) return {};

        // The synthetic workload is deliberately far from integer overflow.
        id += di;
        lat += da;
        lon += dn;

        const auto lat_nano = w.lat_offset + factor * lat;
        const auto lon_nano = w.lon_offset + factor * lon;

        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon_nano));
    }

    return {checksum, ids.empty() && lats.empty() && lons.empty()};
}

Run run_coordinates_checked(const Workload& w) noexcept {
    Cursor ids(w.ids), lats(w.lats), lons(w.lons);
    std::int64_t id = 0, lat = 0, lon = 0;
    std::uint64_t checksum = 0;
    const auto factor = static_cast<std::int64_t>(w.granularity);

    for (std::size_t i = 0; i < w.node_count; ++i) {
        std::int64_t di, da, dn;
        if (!read_triple(ids, lats, lons, di, da, dn)) return {};

        // Keep delta accumulation identical to coordinatesUnchecked so this
        // pair isolates only checked_mul_add versus ordinary multiply/add.
        id += di;
        lat += da;
        lon += dn;

        std::int64_t lat_nano, lon_nano;
        if (!checked_mul_add(w.lat_offset, factor, lat, lat_nano) ||
            !checked_mul_add(w.lon_offset, factor, lon, lon_nano))
            return {};

        checksum = mix(checksum, static_cast<std::uint64_t>(id));
        checksum = mix(checksum, static_cast<std::uint64_t>(lat_nano));
        checksum = mix(checksum, static_cast<std::uint64_t>(lon_nano));
    }

    return {checksum, ids.empty() && lats.empty() && lons.empty()};
}

Run run_stage(const Workload& w, Stage s) noexcept {
    switch (s) {
        case Stage::sint64Decode:
            return run_sint64_decode(w);
        case Stage::deltaUnchecked:
            return run_delta_unchecked(w);
        case Stage::deltaChecked:
            return run_delta_checked(w);
        case Stage::coordinatesUnchecked:
            return run_coordinates_unchecked(w);
        case Stage::coordinatesChecked:
            return run_coordinates_checked(w);
    }
    return {};
}

const char* stage_name(Stage s) noexcept {
    switch (s) {
        case Stage::sint64Decode:
            return "sint64-decode";
        case Stage::deltaUnchecked:
            return "delta-unchecked";
        case Stage::deltaChecked:
            return "delta-checked";
        case Stage::coordinatesUnchecked:
            return "coords-unchecked";
        case Stage::coordinatesChecked:
            return "coords-checked";
    }
    return "?";
}

Stats summarize(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    const auto idx = [&](std::size_t n, std::size_t d) {
        return ((v.size() - 1) * n) / d;
    };
    return {v.front(), v[idx(1,10)], v[idx(1,2)], v[idx(9,10)], v.back()};
}

std::size_t parse_arg(int argc, char** argv, std::string_view name, std::size_t fallback) {
    const std::string_view prefix = name;
    for (int i = 1; i < argc; ++i) {
        std::string_view a(argv[i]);
        if (a.starts_with(prefix)) return static_cast<std::size_t>(std::strtoull(a.data() + prefix.size(), nullptr, 10));
    }
    return fallback;
}

} // namespace

int main(int argc, char** argv) {
    const auto nodes = parse_arg(argc, argv, "--nodes=", 200000);
    const auto iterations = parse_arg(argc, argv, "--iterations=", 1);
    const auto samples = parse_arg(argc, argv, "--samples=", 30);
    const auto warmup = parse_arg(argc, argv, "--warmup=", 2);
    if (!nodes || !samples || iterations != 1) {
        std::fprintf(stderr,
            "nodes and samples must be > 0; iterations must be exactly 1\n");
        return 2;
    }

    const auto w = build_workload(nodes);
    constexpr Stage stages[] = {
        Stage::sint64Decode,
        Stage::deltaUnchecked,
        Stage::deltaChecked,
        Stage::coordinatesUnchecked,
        Stage::coordinatesChecked,
    };
    std::uint64_t expected[5]{};
    for (int i = 0; i < 5; ++i) {
        const auto r = run_stage(w, stages[i]);
        if (!r.ok) return 3;
        expected[i] = r.checksum;
    }

    if (expected[static_cast<int>(Stage::deltaUnchecked)] !=
            expected[static_cast<int>(Stage::deltaChecked)] ||
        expected[static_cast<int>(Stage::coordinatesUnchecked)] !=
            expected[static_cast<int>(Stage::coordinatesChecked)]) {
        std::fprintf(stderr,
            "paired checked/unchecked stage checksum mismatch\n");
        return 3;
    }

#if defined(__clang__)
    std::printf("d-osm DenseNodes C++ coordinate-stage benchmark\ncompiler: Clang %s\n", __clang_version__);
#elif defined(__GNUC__)
    std::printf("d-osm DenseNodes C++ coordinate-stage benchmark\ncompiler: GCC %s\n", __VERSION__);
#else
    std::printf("d-osm DenseNodes C++ coordinate-stage benchmark\ncompiler: unknown\n");
#endif
    std::printf("nodes: %zu  iterations/sample: %zu  samples: %zu  warmup: %zu\n", nodes, iterations, samples, warmup);
    std::printf("encoded bytes: ids=%zu lats=%zu lons=%zu total=%zu\n", w.ids.size(), w.lats.size(), w.lons.size(), w.ids.size()+w.lats.size()+w.lons.size());
    std::printf("stages: sint64-decode; checked/unchecked delta accumulation; checked/unchecked nanodegree conversion\n");
    std::printf("excluded: protobuf field scanning, tags, DenseInfo, node views, workload generation and reporting\n");
    std::printf("ordering: rotating five cyclic orders; balanced over each complete five-sample cycle\n");
    std::printf("statistics: min, p10, p50, p90, max; Δ80=(p90-p10)/p50\n\n");

    volatile std::uint64_t observable = 0;
    constexpr Stage permutations[5][5] = {
        {
            Stage::sint64Decode,
            Stage::deltaUnchecked,
            Stage::deltaChecked,
            Stage::coordinatesUnchecked,
            Stage::coordinatesChecked,
        },
        {
            Stage::deltaUnchecked,
            Stage::deltaChecked,
            Stage::coordinatesUnchecked,
            Stage::coordinatesChecked,
            Stage::sint64Decode,
        },
        {
            Stage::deltaChecked,
            Stage::coordinatesUnchecked,
            Stage::coordinatesChecked,
            Stage::sint64Decode,
            Stage::deltaUnchecked,
        },
        {
            Stage::coordinatesUnchecked,
            Stage::coordinatesChecked,
            Stage::sint64Decode,
            Stage::deltaUnchecked,
            Stage::deltaChecked,
        },
        {
            Stage::coordinatesChecked,
            Stage::sint64Decode,
            Stage::deltaUnchecked,
            Stage::deltaChecked,
            Stage::coordinatesUnchecked,
        },
    };

    for (int si = 0; si < 5; ++si) {
        for (std::size_t wup = 0; wup < warmup; ++wup) {
            const auto r = run_stage(w, stages[si]);
            if (!r.ok || r.checksum != expected[si]) return 3;
            observable ^= r.checksum;
        }
    }

    std::vector<double> times[5];
    for (auto& v : times) v.reserve(samples);
    for (std::size_t sample = 0; sample < samples; ++sample) {
        const auto& order = permutations[sample % 5];
        for (Stage stage : order) {
            const int si = static_cast<int>(stage);
            const auto start = std::chrono::steady_clock::now();
            std::uint64_t sum = 0;
            bool ok = true;
            for (std::size_t it = 0; it < iterations; ++it) {
                const auto r = run_stage(w, stage);
                sum += r.checksum;
                ok = ok && r.ok && r.checksum == expected[si];
            }
            const auto stop = std::chrono::steady_clock::now();
            if (!ok) return 3;
            observable ^= sum;
            const auto ns = std::chrono::duration<double, std::nano>(stop - start).count();
            times[si].push_back(ns / static_cast<double>(nodes * iterations));
        }
    }

    for (int si = 0; si < 5; ++si) {
        const auto stage = stages[si];
        const auto st = summarize(times[si]);
        const double delta80 = st.p50 == 0 ? 0 : (st.p90 - st.p10) / st.p50 * 100.0;
        const double mnode = st.p50 == 0 ? 0 : 1000.0 / st.p50;
        std::printf("%-12s p50=%8.3f ns/node %7.2f Mnode/s  p10=%8.3f p90=%8.3f Δ80=%5.1f%%  min=%8.3f max=%8.3f  checksum=%016llx\n",
            stage_name(stage), st.p50, mnode, st.p10, st.p90, delta80, st.min, st.max,
            static_cast<unsigned long long>(expected[si]));
    }
    if (observable == UINT64_C(0xdeadbeef)) std::puts("observable");
    return 0;
}
