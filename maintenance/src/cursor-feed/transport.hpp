#pragma once

#include "../protocol/cursor_packet.h"
#include "../protocol/cursor_socket.h"

#include <sys/socket.h>
#include <sys/un.h>

#include <cstdint>

namespace qs::cursor_feed {
struct TickResult final {
    bool sent = false;
    bool retry = false;
};

class Transport final {
public:
    Transport() noexcept = default;
    ~Transport();

    Transport(const Transport&) = delete;
    Transport& operator=(const Transport&) = delete;

    void initialize() noexcept;
    void shutdown() noexcept;
    void record(float x, float y) noexcept;
    TickResult publishTick() noexcept;

private:
    struct State final {
        float x = 0.0F;
        float y = 0.0F;
        std::uint32_t serial = 0;
        int fd = -1;
        bool dirty = false;
        bool connecting = false;
        std::uint8_t retryTicks = 0;
    };

    State m_state{};
    sockaddr_un m_address{};
    socklen_t m_addressLength = 0;
    bool m_addressValid = false;

    void closeSocket() noexcept;
    bool beginConnect() noexcept;
    bool connectionReady() noexcept;
};
}
