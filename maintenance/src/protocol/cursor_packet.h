#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <type_traits>

namespace qs::cursor {
inline constexpr std::uint32_t ProtocolVersion = 1u;
inline constexpr std::uint32_t VersionMask = 0x0Fu;

struct Packet final {
    float x;
    float y;
    std::uint32_t serial;
    std::uint32_t flags;
};

static_assert(sizeof(Packet) == 16, "CursorPacket must remain exactly 16 bytes");
static_assert(alignof(Packet) == alignof(float));
static_assert(std::is_trivially_copyable_v<Packet>);

inline bool isVersionValid(const Packet& p) noexcept {
    return (p.flags & VersionMask) == ProtocolVersion;
}

inline std::array<std::byte, sizeof(Packet)> encode(const Packet& p) noexcept {
    std::array<std::byte, sizeof(Packet)> bytes{};
    std::memcpy(bytes.data(), &p, sizeof p);
    return bytes;
}

inline Packet decode(const void* data) noexcept {
    Packet p{};
    std::memcpy(&p, data, sizeof p);
    return p;
}
}
