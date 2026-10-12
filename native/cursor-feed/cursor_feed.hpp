#pragma once

#include <cstdint>

namespace cursor_feed {

struct TickResult {
    bool retry = false;
    std::uint32_t retryDelayMs = 0;
};

void initialize(float initialX, float initialY) noexcept;
void shutdown() noexcept;
bool mouseMove(double x, double y) noexcept;
bool hasPendingPublication() noexcept;
TickResult compositorDispatchTick() noexcept;

} // namespace cursor_feed
