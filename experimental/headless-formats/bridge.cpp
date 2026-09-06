// Aquamarine 0.15.0 experiment: use negotiated parent Wayland modifiers when
// there is no DRM backend. Never preload this into the user's compositor.
#include <aquamarine/backend/Headless.hpp>

std::vector<Aquamarine::SDRMFormat> Aquamarine::CHeadlessBackend::getRenderFormats() {
    const auto owner = backend.lock();
    if (!owner) return {};
    for (const auto& impl : owner->getImplementations()) {
        if (impl->type() != AQ_BACKEND_DRM) continue;
        auto formats = impl->getRenderableFormats();
        if (!formats.empty()) return formats;
    }
    for (const auto& impl : owner->getImplementations()) {
        if (impl->type() != AQ_BACKEND_WAYLAND) continue;
        auto formats = impl->getRenderFormats();
        if (!formats.empty()) return formats;
    }
    // Fail closed: do not invent an unsupported modifier.
    return {};
}
