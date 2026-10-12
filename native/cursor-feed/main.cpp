#include "cursor_feed.hpp"

#include <plugins/PluginAPI.hpp>
#include <event/EventBus.hpp>
#include <managers/input/InputManager.hpp>
#include <output/Monitor.hpp>
#include <state/MonitorState.hpp>

#include <stdexcept>
#include <string>

namespace {

Hyprutils::Signal::CHyprSignalListener g_mouseMove;
Hyprutils::Signal::CHyprSignalListener g_renderPreChecks;
PHLMONITORREF g_cursorMonitor;

[[nodiscard]] bool contains(const PHLMONITOR& monitor, double x, double y) noexcept {
    if (!monitor)
        return false;

    const double left = monitor->m_position.x;
    const double top = monitor->m_position.y;
    const double right = left + monitor->m_size.x;
    const double bottom = top + monitor->m_size.y;
    return x >= left && x < right && y >= top && y < bottom;
}

[[nodiscard]] PHLMONITOR monitorForCursor(double x, double y) noexcept {
    if (auto cached = g_cursorMonitor.lock(); cached && contains(cached, x, y))
        return cached;

    const auto monitor = State::monitorState()->query().vec(Vector2D{x, y}).run();
    g_cursorMonitor = monitor;
    return monitor;
}

struct MouseMoveListener {
    template<typename Position, typename... Rest>
    void operator()(Position&& position, Rest&&...) const noexcept {
        // The high-frequency sensor section remains native fixed state only.
        // No socket, filesystem, logging, allocation, or process execution is
        // performed by cursor_feed::mouseMove().
        if (!cursor_feed::mouseMove(position.x, position.y))
            return;

        // A cursor-dependent surface needs a real monitor frame to remain live
        // when Hyprland itself has no other frame demand. The cache makes this a
        // cheap pointer/bounds check for ordinary motion; a spatial query occurs
        // only when crossing monitor bounds.
        const auto monitor = monitorForCursor(position.x, position.y);
        if (monitor)
            monitor->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_CURSOR_MOVE);
    }
};

void renderPreChecks(PHLMONITOR monitor) noexcept {
    const auto result = cursor_feed::compositorDispatchTick();
    if (!result.retry || !monitor)
        return;

    // Retain newest-state semantics. A failed nonblocking send is retried only
    // through the already active compositor frame path.
    monitor->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_NEEDS_FRAME);
}

} // namespace

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE) {
    if (std::string(__hyprland_api_get_hash()) != std::string(__hyprland_api_get_client_hash()))
        throw std::runtime_error("cursor-feed: Hyprland headers/API hash mismatch");

    if (!g_pInputManager)
        throw std::runtime_error("cursor-feed: Hyprland input manager unavailable");

    auto&& bus = Event::bus();
    if (!bus)
        throw std::runtime_error("cursor-feed: Hyprland event bus unavailable");

    const auto initialCursor = g_pInputManager->getMouseCoordsInternal();
    cursor_feed::initialize(
        static_cast<float>(initialCursor.x),
        static_cast<float>(initialCursor.y));

    g_cursorMonitor = State::monitorState()->query().vec(initialCursor).run();

    g_renderPreChecks = bus->m_events.render.preChecks.listen(renderPreChecks);
    g_mouseMove = bus->m_events.input.mouse.move.listen(MouseMoveListener{});

    if (const auto monitor = g_cursorMonitor.lock())
        monitor->scheduleFrame(Aquamarine::IOutput::AQ_SCHEDULE_CURSOR_MOVE);

    return {"cursor-feed", "minimal cursor sensor transport", "shell-rewrite", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_renderPreChecks.reset();
    g_mouseMove.reset();
    g_cursorMonitor.reset();
    cursor_feed::shutdown();
}
