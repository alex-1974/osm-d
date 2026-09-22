// SPDX-License-Identifier: MIT
//
// Direct whole-buffer libosmium reference for the osm-d decode-count benchmark.
//
// File I/O is outside the measured parser work. The benchmark walks the
// already-loaded compressed PBF bytes directly:
//
//   framing -> BlobHeader -> Blob/decompression -> HeaderBlock/PrimitiveBlock
//   -> libosmium object materialization -> node/way/relation/tag counts
//
// This intentionally bypasses osmium::io::Reader for the in-memory benchmark.
// libosmium's Reader buffer input path receives the complete input through
// NoDecompressor in one std::string and repeatedly erases consumed prefixes,
// which introduces large implementation-specific memmove costs unrelated to
// PBF decoding.
//
// In --measure mode one untimed warm-up decode is followed by one timed decode.
//
// Authors: Alexander Bernardi
// Date: 2026-09-22
// Copyright: Copyright © 2026 Alexander Bernardi
// License: MIT

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <exception>
#include <fstream>
#include <iostream>
#include <iterator>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <osmium/handler.hpp>
#include <osmium/io/detail/pbf.hpp>
#include <osmium/io/detail/pbf_decoder.hpp>
#include <osmium/io/detail/protobuf_tags.hpp>
#include <osmium/io/error.hpp>
#include <osmium/visitor.hpp>

#include <protozero/pbf_message.hpp>

namespace {

struct Counts {
    std::uint64_t nodes = 0;
    std::uint64_t ways = 0;
    std::uint64_t relations = 0;
    std::uint64_t tags = 0;
    std::uint64_t header_blocks = 0;
    std::uint64_t data_blocks = 0;

    friend bool operator==(const Counts& lhs, const Counts& rhs) noexcept {
        return lhs.nodes == rhs.nodes &&
               lhs.ways == rhs.ways &&
               lhs.relations == rhs.relations &&
               lhs.tags == rhs.tags &&
               lhs.header_blocks == rhs.header_blocks &&
               lhs.data_blocks == rhs.data_blocks;
    }
};

struct CountHandler : public osmium::handler::Handler {
    Counts* counts = nullptr;

    explicit CountHandler(Counts& target) noexcept :
        counts(&target) {
    }

    void node(const osmium::Node& node) noexcept {
        ++counts->nodes;
        counts->tags += node.tags().size();
    }

    void way(const osmium::Way& way) noexcept {
        ++counts->ways;
        counts->tags += way.tags().size();
    }

    void relation(const osmium::Relation& relation) noexcept {
        ++counts->relations;
        counts->tags += relation.tags().size();
    }
};

void count_buffer_chain(osmium::memory::Buffer buffer, Counts& counts) {
    // PBFPrimitiveBlockDecoder uses Buffer::auto_grow::internal. When the
    // current buffer grows, previously committed storage is retained as
    // nested buffers. Reader::read() normally exposes those buffers one by
    // one; the direct benchmark must therefore drain the complete chain.
    while (buffer.has_nested_buffers()) {
        auto nested = buffer.get_last_nested();
        count_buffer_chain(std::move(*nested), counts);
    }

    CountHandler handler{counts};
    osmium::apply(buffer, handler);
}

std::uint32_t read_be32(const char* data) noexcept {
    const auto* p = reinterpret_cast<const unsigned char*>(data);
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

struct BlobHeader {
    std::string type;
    std::size_t data_size = 0;
};

BlobHeader decode_blob_header(const char* data, std::size_t size) {
    using namespace osmium::io::detail;

    protozero::pbf_message<FileFormat::BlobHeader> message{
        protozero::data_view{data, size}
    };

    BlobHeader result;
    bool saw_type = false;
    bool saw_data_size = false;

    while (message.next()) {
        switch (message.tag_and_type()) {
            case protozero::tag_and_type(
                FileFormat::BlobHeader::required_string_type,
                protozero::pbf_wire_type::length_delimited): {
                const auto value = message.get_view();
                result.type.assign(value.data(), value.size());
                saw_type = true;
                break;
            }

            case protozero::tag_and_type(
                FileFormat::BlobHeader::required_int32_datasize,
                protozero::pbf_wire_type::varint): {
                const auto value = message.get_int32();
                if (value <= 0) {
                    throw osmium::pbf_error{
                        "PBF format error: BlobHeader.datasize missing or zero."
                    };
                }
                result.data_size = static_cast<std::size_t>(value);
                saw_data_size = true;
                break;
            }

            default:
                message.skip();
        }
    }

    if (!saw_type || result.type.empty()) {
        throw osmium::pbf_error{
            "PBF format error: BlobHeader.type missing or empty."
        };
    }

    if (!saw_data_size || result.data_size == 0) {
        throw osmium::pbf_error{
            "PBF format error: BlobHeader.datasize missing or zero."
        };
    }

    if (result.data_size > osmium::io::detail::max_uncompressed_blob_size) {
        throw osmium::pbf_error{"invalid blob size"};
    }

    return result;
}

Counts decode_buffer(const std::vector<char>& bytes) {
    using namespace osmium::io;
    using namespace osmium::io::detail;

    Counts counts;
    std::size_t offset = 0;
    bool saw_header = false;
    bool saw_data = false;

    while (offset < bytes.size()) {
        if (bytes.size() - offset < sizeof(std::uint32_t)) {
            throw osmium::pbf_error{
                "truncated PBF framing before BlobHeader size"
            };
        }

        const std::uint32_t header_size = read_be32(bytes.data() + offset);
        offset += sizeof(std::uint32_t);

        if (header_size == 0 ||
            header_size > static_cast<std::uint32_t>(max_blob_header_size)) {
            throw osmium::pbf_error{"invalid BlobHeader size"};
        }

        if (bytes.size() - offset < header_size) {
            throw osmium::pbf_error{"truncated BlobHeader"};
        }

        const BlobHeader header =
            decode_blob_header(bytes.data() + offset, header_size);
        offset += header_size;

        if (bytes.size() - offset < header.data_size) {
            throw osmium::pbf_error{"truncated Blob"};
        }

        std::string blob{
            bytes.data() + offset,
            header.data_size
        };
        offset += header.data_size;

        if (header.type == "OSMHeader") {
            if (saw_header || saw_data) {
                throw osmium::pbf_error{
                    "OSMHeader must occur exactly once before OSMData"
                };
            }

            // Includes Blob decompression and required-feature validation.
            const auto decoded_header = decode_header(blob);
            (void)decoded_header;

            saw_header = true;
            ++counts.header_blocks;
            continue;
        }

        if (header.type == "OSMData") {
            if (!saw_header) {
                throw osmium::pbf_error{
                    "OSMData encountered before OSMHeader"
                };
            }

            saw_data = true;

            PBFDataBlobDecoder decoder{
                std::move(blob),
                osmium::osm_entity_bits::all,
                osmium::io::read_meta::yes
            };

            osmium::memory::Buffer buffer = decoder();
            count_buffer_chain(std::move(buffer), counts);

            ++counts.data_blocks;
            continue;
        }

        throw osmium::pbf_error{
            std::string{"unsupported PBF blob type: "} + header.type
        };
    }

    if (!saw_header) {
        throw osmium::pbf_error{"missing OSMHeader"};
    }

    return counts;
}

void print_counts(std::size_t byte_count, const Counts& counts) {
    std::cout
        << "bytes=" << byte_count << '\n'
        << "header_blocks=" << counts.header_blocks << '\n'
        << "data_blocks=" << counts.data_blocks << '\n'
        << "nodes=" << counts.nodes << '\n'
        << "ways=" << counts.ways << '\n'
        << "relations=" << counts.relations << '\n'
        << "tags=" << counts.tags << '\n';
}

} // namespace

int main(int argc, char** argv) {
    bool measure = false;
    const char* filename = nullptr;

    if (argc == 2) {
        filename = argv[1];
    } else if (argc == 3 && std::string{argv[1]} == "--measure") {
        measure = true;
        filename = argv[2];
    } else {
        std::cerr << "usage: " << argv[0]
                  << " [--measure] FILE.osm.pbf\n";
        return 2;
    }

    std::ifstream input{filename, std::ios::binary};
    if (!input) {
        std::cerr << "cannot open input: " << filename << '\n';
        return 2;
    }

    std::vector<char> bytes{
        std::istreambuf_iterator<char>{input},
        std::istreambuf_iterator<char>{}
    };

    try {
        if (!measure) {
            const Counts counts = decode_buffer(bytes);
            print_counts(bytes.size(), counts);
            return 0;
        }

        const Counts warm_counts = decode_buffer(bytes);

        const auto begin = std::chrono::steady_clock::now();
        const Counts counts = decode_buffer(bytes);
        const auto end = std::chrono::steady_clock::now();

        if (!(counts == warm_counts)) {
            std::cerr
                << "non-deterministic counts between warm-up and measured decode\n";
            return 1;
        }

        const auto elapsed_ns =
            std::chrono::duration_cast<std::chrono::nanoseconds>(
                end - begin).count();

        std::cout << "elapsed_ns=" << elapsed_ns << '\n';
        print_counts(bytes.size(), counts);
    } catch (const std::exception& e) {
        std::cerr << "libosmium error: " << e.what() << '\n';
        return 1;
    }

    return 0;
}
