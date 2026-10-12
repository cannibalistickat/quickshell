#include "transport.hpp"

#include <plugins/PluginAPI.hpp>
#include <event/EventBus.hpp>
#include <stdexcept>
#include <string>

namespace {
qs::cursor_feed::Transport g_transport;
Hyprutils::Signal::CHyprSignalListener g_mouseMove;
Hyprutils::Signal::CHyprSignalListener g_renderPreChecks;

struct MouseMoveListener final {
    template<typename Position, typename... Rest>
    void operator()(Position&& position, Rest&&...) const noexcept {
        g_transport.record(static_cast<float>(position.x), static_cast<float>(position.y));
    }
};

void publishAtRenderBoundary(PHLMONITOR) noexcept {
    (void)g_transport.publishTick();
}
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    (void)handle;

    if (std::string(__hyprland_api_get_hash()) != std::string(__hyprland_api_get_client_hash()))
        throw std::runtime_error("quickshell-cursor-feed: Hyprland API hash mismatch");

    auto&& bus = Event::bus();
    if (!bus)
        throw std::runtime_error("quickshell-cursor-feed: event bus unavailable");
    g_transport.initialize();

    g_mouseMove = bus->m_events.input.mouse.move.listen(MouseMoveListener{});
    g_renderPreChecks = bus->m_events.render.preChecks.listen(publishAtRenderBoundary);

    return {
        "quickshell-cursor-feed",
        "latest-state cursor transport for Quickshell",
        "quickshell-greenfield",
        "3.0",
    };
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_renderPreChecks.reset();
    g_mouseMove.reset();
    g_transport.shutdown();
}
