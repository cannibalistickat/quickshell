#include "transport.hpp"

#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <cstdint>

namespace qs::cursor_feed {
namespace {
constexpr std::uint8_t MaxRetryTicks = 32;

bool transient(int error) noexcept {
    return error == EINTR || error == EAGAIN || error == EWOULDBLOCK;
}
}

Transport::~Transport() {
    shutdown();
}

void Transport::initialize() noexcept {
    shutdown();
    m_addressLength = qs::cursor::makeAbstractAddress(m_address);
    m_addressValid = m_addressLength != 0;
}

void Transport::shutdown() noexcept {
    closeSocket();
    m_state = {};
    m_address = {};
    m_addressLength = 0;
    m_addressValid = false;
}

void Transport::record(float x, float y) noexcept {
    if (x == m_state.x && y == m_state.y)
        return;

    m_state.x = x;
    m_state.y = y;
    ++m_state.serial;
    m_state.dirty = true;
}

void Transport::closeSocket() noexcept {
    if (m_state.fd >= 0)
        ::close(m_state.fd);
    m_state.fd = -1;
    m_state.connecting = false;
}

bool Transport::beginConnect() noexcept {
    if (!m_addressValid || m_state.fd >= 0)
        return false;

    const int fd = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (fd < 0)
        return false;

    const int result = ::connect(
        fd,
        reinterpret_cast<const sockaddr*>(&m_address),
        m_addressLength);

    if (result == 0) {
        m_state.fd = fd;
        m_state.connecting = false;
        m_state.retryTicks = 0;
        return true;
    }

    if (errno == EINPROGRESS || errno == EINTR) {
        m_state.fd = fd;
        m_state.connecting = true;
        return true;
    }

    ::close(fd);
    return false;
}

bool Transport::connectionReady() noexcept {
    if (m_state.fd < 0)
        return false;
    if (!m_state.connecting)
        return true;

    int error = 0;
    socklen_t size = sizeof error;
    if (::getsockopt(m_state.fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0) {
        closeSocket();
        return false;
    }

    if (error == 0) {
        m_state.connecting = false;
        return true;
    }

    if (error == EINPROGRESS || error == EALREADY || error == EINTR)
        return false;

    closeSocket();
    return false;
}

TickResult Transport::publishTick() noexcept {
    if (!m_state.dirty)
        return {};

    if (m_state.fd < 0) {
        if (m_state.retryTicks != 0) {
            --m_state.retryTicks;
            return {.retry = true};
        }

        if (!beginConnect()) {
            m_state.retryTicks = MaxRetryTicks;
            return {.retry = true};
        }
    }

    if (!connectionReady()) {
        if (!m_state.connecting) {
            closeSocket();
            m_state.retryTicks = MaxRetryTicks;
        }
        return {.retry = true};
    }

    if (m_state.connecting)
        return {.retry = true};

    const qs::cursor::Packet packet{
        m_state.x,
        m_state.y,
        m_state.serial,
        qs::cursor::ProtocolVersion,
    };

    const ssize_t count = ::send(
        m_state.fd,
        &packet,
        sizeof packet,
        MSG_DONTWAIT | MSG_NOSIGNAL);

    if (count == static_cast<ssize_t>(sizeof packet)) {
        m_state.dirty = false;
        m_state.retryTicks = 0;
        return {.sent = true};
    }

    if (count < 0 && transient(errno))
        return {.retry = true};

    closeSocket();
    m_state.retryTicks = MaxRetryTicks;
    return {.retry = true};
}
}
