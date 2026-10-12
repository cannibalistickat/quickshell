#include "cursor_feed.hpp"

#include "../../protocol/CursorPacket.h"
#include "../../protocol/CursorSocket.h"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>

namespace cursor_feed {
namespace {

sockaddr_un g_address{};
socklen_t g_addressLength = 0;
bool g_addressValid = false;

int g_fd = -1;
bool g_connecting = false;

float g_x = 0.0f;
float g_y = 0.0f;
std::uint32_t g_serial = 0;
bool g_dirty = false;

std::uint32_t g_retryDelayMs = 1;

void resetRetryBackoff() noexcept {
    g_retryDelayMs = 1;
}

[[nodiscard]] std::uint32_t nextRetryDelay() noexcept {
    const std::uint32_t delay = g_retryDelayMs;
    g_retryDelayMs = g_retryDelayMs < 16 ? g_retryDelayMs * 2 : 16;
    return delay;
}

void markConnectionSuccess() noexcept {
    g_connecting = false;
    resetRetryBackoff();
}

void dropConnection() noexcept {
    if (g_fd >= 0)
        ::close(g_fd);

    g_fd = -1;
    g_connecting = false;
    // Keep the newest position dirty. A future real cursor movement or a
    // bounded retry from an already-requested frame can publish it.
    g_dirty = true;
}

enum class ConnectResult {
    Failed,
    Connecting,
    Connected,
};

[[nodiscard]] ConnectResult beginConnection() noexcept {
    if (g_fd >= 0 || !g_addressValid)
        return ConnectResult::Failed;

    const int fd = ::socket(
        AF_UNIX,
        SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC,
        0);
    if (fd < 0)
        return ConnectResult::Failed;

    const int result = ::connect(
        fd,
        reinterpret_cast<const sockaddr*>(&g_address),
        g_addressLength);

    if (result == 0) {
        g_fd = fd;
        markConnectionSuccess();
        return ConnectResult::Connected;
    }

    if (errno == EINPROGRESS) {
        g_fd = fd;
        g_connecting = true;
        return ConnectResult::Connecting;
    }

    ::close(fd);
    return ConnectResult::Failed;
}

[[nodiscard]] bool connectionReady() noexcept {
    if (!g_connecting)
        return true;

    int error = 0;
    socklen_t size = sizeof(error);
    if (::getsockopt(g_fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0) {
        dropConnection();
        return false;
    }

    if (error == 0) {
        markConnectionSuccess();
        return true;
    }

    if (error == EINPROGRESS || error == EALREADY || error == EINTR)
        return false;

    dropConnection();
    return false;
}

} // namespace

void initialize(float initialX, float initialY) noexcept {
    g_addressLength = cursor_protocol::fillSocketAddress(g_address);
    g_addressValid = g_addressLength != 0;

    g_x = initialX;
    g_y = initialY;
    g_serial = 1;
    g_dirty = true;

    g_fd = -1;
    g_connecting = false;
    resetRetryBackoff();
}

void shutdown() noexcept {
    if (g_fd >= 0)
        ::close(g_fd);

    g_fd = -1;
    g_connecting = false;
    g_dirty = false;
    g_addressValid = false;
    g_addressLength = 0;
    resetRetryBackoff();
}

bool hasPendingPublication() noexcept {
    return g_dirty;
}

bool mouseMove(double x, double y) noexcept {
    const float nextX = static_cast<float>(x);
    const float nextY = static_cast<float>(y);

    if (nextX == g_x && nextY == g_y)
        return false;

    g_x = nextX;
    g_y = nextY;
    ++g_serial;
    g_dirty = true;
    return true;
}

TickResult compositorDispatchTick() noexcept {
    if (!g_dirty)
        return {};

    if (g_fd < 0) {
        const ConnectResult connection = beginConnection();
        if (connection == ConnectResult::Failed) {
            // Do not poll for a consumer. The next real cursor movement will
            // generate another requested publication opportunity.
            g_dirty = false;
            return {};
        }

        if (connection == ConnectResult::Connecting)
            return {.retry = true, .retryDelayMs = nextRetryDelay()};
    }

    if (!connectionReady())
        return {.retry = true, .retryDelayMs = nextRetryDelay()};

    const cursor_protocol::Packet packet{
        g_x,
        g_y,
        g_serial,
        cursor_protocol::ProtocolVersion,
    };

    const ssize_t result = ::send(
        g_fd,
        &packet,
        sizeof(packet),
        MSG_DONTWAIT | MSG_NOSIGNAL);

    if (result == static_cast<ssize_t>(sizeof(packet))) {
        g_dirty = false;
        resetRetryBackoff();
        return {};
    }

    if (result < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
            return {.retry = true, .retryDelayMs = nextRetryDelay()};

        dropConnection();
        return {};
    }

    // SOCK_SEQPACKET should either accept the complete datagram or fail; treat
    // any anomalous partial result as a broken connection and retain latest state.
    dropConnection();
    return {};
}

} // namespace cursor_feed
