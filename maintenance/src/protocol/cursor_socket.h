#pragma once

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstddef>
#include <cstring>
#include <string_view>
#include <charconv>

namespace qs::cursor {
inline constexpr std::string_view SocketPrefix = "quickshell-cursor-v1-";

inline socklen_t makeAbstractAddress(sockaddr_un& address) noexcept {
    std::memset(&address, 0, sizeof address);
    address.sun_family = AF_UNIX;
    address.sun_path[0] = '\0';

    constexpr std::size_t capacity = sizeof(address.sun_path) - 1u;
    if (SocketPrefix.size() + 1u > capacity)
        return 0;

    std::memcpy(address.sun_path + 1, SocketPrefix.data(), SocketPrefix.size());
    char* const begin = address.sun_path + 1 + SocketPrefix.size();
    char* const end = address.sun_path + sizeof address.sun_path;
    const auto [written, error] = std::to_chars(begin, end, static_cast<unsigned long long>(::geteuid()));
    if (error != std::errc{})
        return 0;

    const std::size_t nameLength = static_cast<std::size_t>(written - address.sun_path);
    return static_cast<socklen_t>(offsetof(sockaddr_un, sun_path) + nameLength);
}
}
