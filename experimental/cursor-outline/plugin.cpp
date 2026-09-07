// Optional Hyprland 0.56.2 bridge. The CLI and input backends remain Zig.
// Never auto-loaded: first validate this against a disposable compositor.
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cmath>
#include <array>
#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <stdexcept>
#include <string_view>
#include <vector>

static_assert(std::string_view{GIT_TAG} == "v0.56.2", "hyprhand outline requires Hyprland v0.56.2 headers");
static_assert(std::string_view{HYPRLAND_API_VERSION} == "0.1", "Re-audit the plugin API before upgrading");
static_assert([] {
    constexpr std::string_view hash{GIT_COMMIT_HASH};
    return hash.size() == 40 && hash.find_first_not_of("0123456789abcdef") == hash.npos;
}(), "Hyprland headers must contain a full commit hash");

namespace {
HANDLE handle = nullptr;
bool dispatcherRegistered = false;
wl_event_source* timer = nullptr;
CHyprSignalListener renderListener, shapeListener;
std::string controlPath, token;
bool active = false, dirty = true, cursorVisible = false;
CBox previous;
SP<Render::ITexture> glow;
WP<Render::ITexture> lastSource;
GLuint lastSourceID = 0;
Vector2D lastSourceSize;
Render::eTextureType lastSourceType = Render::TEXTURE_INVALID;
eTransform lastSourceTransform = HYPRUTILS_TRANSFORM_NORMAL;
constexpr int PAD = 7;
int sourceW = 0, sourceH = 0;

CBox damageCursor() {
    auto box = Pointer::mgr()->getCursorBoxGlobal();
    // Padding lives in texture pixels, whereas damage uses global logical units.
    const double scale = sourceW > 0 && sourceH > 0 ? std::max(box.w / sourceW, box.h / sourceH) : 1.;
    return box.expand(PAD * std::max(1., scale) + 2);
}

std::string readToken(const std::string& path) {
    const int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return {};
    struct stat st{};
    char bytes[33]{};
    const bool safe = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() && (st.st_mode & 077) == 0 && st.st_size == 32;
    const auto n = safe ? read(fd, bytes, sizeof(bytes)) : -1;
    close(fd);
    if (n != 32) return {};
    for (int i = 0; i < 32; ++i) if (!std::isxdigit(static_cast<unsigned char>(bytes[i]))) return {};
    return std::string(bytes, 32);
}

void deactivate() {
    if (active && g_pHyprRenderer) g_pHyprRenderer->damageBox(previous);
    active = false;
    cursorVisible = false;
    controlPath.clear();
    token.clear();
    dirty = true;
    // In the pinned version CGLTexture's destructor makes its EGL context
    // current (and checks compositor shutdown). No render callback is needed.
    glow.reset();
    lastSource.reset();
    lastSourceID = 0;
    sourceW = sourceH = 0;
}

void invalidate() {
    dirty = true;
    if (!active) return;
    // Damage now: render may consume dirty before the next timer callback.
    g_pHyprRenderer->damageBox(previous);
    g_pHyprRenderer->damageBox(damageCursor());
}

void stopTimer() {
    if (timer) wl_event_source_remove(timer);
    timer = nullptr;
}

void cleanup() {
    stopTimer();
    renderListener.reset();
    shapeListener.reset();
    if (dispatcherRegistered) HyprlandAPI::removeDispatcher(handle, "hyprhand:outline");
    dispatcherRegistered = false;
    deactivate();
    handle = nullptr;
}

int tick(void*) {
    if (active) {
        if (readToken(controlPath) != token) deactivate();
        else {
            const bool visible = g_pHyprRenderer->shouldRenderCursor();
            const auto box = damageCursor();
            if (dirty || visible != cursorVisible || box.x != previous.x || box.y != previous.y || box.w != previous.w || box.h != previous.h) {
                g_pHyprRenderer->damageBox(previous);
                g_pHyprRenderer->damageBox(box);
                previous = box;
            }
            cursorVisible = visible;
        }
    }
    if (timer && wl_event_source_timer_update(timer, 20) < 0) {
        stopTimer();
        deactivate();
    }
    return 0;
}

// CPU pointers must not be interpreted as pixel-buffer offsets, nor use the
// compositor's row strides/skips. Restore state on every return/exception.
struct PixelTransferState {
    GLint readFBO = 0, packBuffer = 0, unpackBuffer = 0, texture = 0;
    static constexpr std::array<GLenum, 8> names = {
        GL_PACK_ALIGNMENT, GL_PACK_ROW_LENGTH, GL_PACK_SKIP_PIXELS, GL_PACK_SKIP_ROWS,
        GL_UNPACK_ALIGNMENT, GL_UNPACK_ROW_LENGTH, GL_UNPACK_SKIP_PIXELS, GL_UNPACK_SKIP_ROWS};
    std::array<GLint, names.size()> values{};
    GLuint fbo = 0;

    PixelTransferState() {
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFBO);
        glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &packBuffer);
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpackBuffer);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
        for (size_t i = 0; i < names.size(); ++i) glGetIntegerv(names[i], &values[i]);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        for (const auto name : names)
            glPixelStorei(name, name == GL_PACK_ALIGNMENT || name == GL_UNPACK_ALIGNMENT ? 1 : 0);
        glGenFramebuffers(1, &fbo);
    }
    ~PixelTransferState() {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, readFBO);
        if (fbo) glDeleteFramebuffers(1, &fbo);
        glBindBuffer(GL_PIXEL_PACK_BUFFER, packBuffer);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpackBuffer);
        glBindTexture(GL_TEXTURE_2D, texture);
        for (size_t i = 0; i < names.size(); ++i) glPixelStorei(names[i], values[i]);
    }
    PixelTransferState(const PixelTransferState&) = delete;
    PixelTransferState& operator=(const PixelTransferState&) = delete;
};

bool makeGlow(const SP<Render::ITexture>& source) {
    glow.reset();
    sourceW = sourceH = 0;
    if (!source || source->m_type != Render::TEXTURE_RGBA || source->m_texID == 0 || source->m_transform != HYPRUTILS_TRANSFORM_NORMAL) return false;
    // Validate floating-point dimensions before narrowing or allocating.
    if (!std::isfinite(source->m_size.x) || !std::isfinite(source->m_size.y) ||
        source->m_size.x < 1 || source->m_size.y < 1 || source->m_size.x > 256 || source->m_size.y > 256 ||
        std::floor(source->m_size.x) != source->m_size.x || std::floor(source->m_size.y) != source->m_size.y) return false;
    const int w = source->m_size.x, h = source->m_size.y;
    std::vector<uint8_t> pixels(w * h * 4);
    // A pre-existing GL error makes this attempt inconclusive; do not use it.
    if (glGetError() != GL_NO_ERROR) return false;
    const PixelTransferState state;
    if (!state.fbo) return false;
    glBindFramebuffer(GL_READ_FRAMEBUFFER, state.fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, source->m_texID, 0);
    if (glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    if (glGetError() != GL_NO_ERROR) return false;
    unsigned visible = 0;
    for (int i = 0; i < w * h; ++i) visible += pixels[i * 4 + 3] > 0;
    if (!visible || visible == static_cast<unsigned>(w * h)) return false;
    const int gw = w + PAD * 2, gh = h + PAD * 2;
    std::vector<uint8_t> rgba(gw * gh * 4, 0);
    static const auto weights = [] {
        std::array<float, (2 * PAD + 1) * (2 * PAD + 1)> values{};
        for (int dy = -PAD; dy <= PAD; ++dy) for (int dx = -PAD; dx <= PAD; ++dx)
            values[(dy + PAD) * (2 * PAD + 1) + dx + PAD] = std::exp(-(dx * dx + dy * dy) / 13.F);
        return values;
    }();
    // Soft dilation of the real alpha mask, not a generic circle or arrow.
    for (int y = 0; y < gh; ++y) for (int x = 0; x < gw; ++x) {
        float value = 0;
        for (int dy = -PAD; dy <= PAD; ++dy) for (int dx = -PAD; dx <= PAD; ++dx) {
            const int sx = x - PAD + dx, sy = y - PAD + dy;
            if (sx < 0 || sy < 0 || sx >= w || sy >= h) continue;
            const float weight = weights[(dy + PAD) * (2 * PAD + 1) + dx + PAD];
            value = std::max(value, pixels[(sy * w + sx) * 4 + 3] / 255.F * weight);
        }
        const int sx = x - PAD, sy = y - PAD;
        const float center = sx >= 0 && sy >= 0 && sx < w && sy < h ? pixels[(sy * w + sx) * 4 + 3] / 255.F : 0;
        const float a = value * (1 - center) * .85F;
        const int i = (y * gw + x) * 4;
        rgba[i] = 35 * a; rgba[i + 1] = 150 * a; rgba[i + 2] = 255 * a; rgba[i + 3] = 255 * a;
    }
    glow = g_pHyprRenderer->createTexture(DRM_FORMAT_ABGR8888, rgba.data(), gw * 4, Vector2D{gw, gh});
    if (glGetError() != GL_NO_ERROR || !glow || !glow->ok()) {
        glow.reset();
        return false;
    }
    sourceW = w; sourceH = h;
    return !!glow;
}

void render(eRenderStage stage) {
    if (stage != RENDER_LAST_MOMENT || !active) return;
    if (readToken(controlPath) != token) { deactivate(); return; }
    if (!g_pHyprRenderer->shouldRenderCursor()) return;
    const auto monitor = g_pHyprRenderer->renderData().pMonitor.lock();
    if (!monitor) return;
    const auto source = Pointer::mgr()->getCurrentCursorTexture();
    // Do not keep old cursor textures alive. Signals cover same-texture surface
    // commits; this also catches replacements/metadata changes during rendering.
    if (lastSource.lock() != source || (source && (source->m_texID != lastSourceID || source->m_size != lastSourceSize ||
        source->m_type != lastSourceType || source->m_transform != lastSourceTransform))) dirty = true;
    if (dirty) {
        makeGlow(source);
        lastSource = source;
        lastSourceID = source ? source->m_texID : 0;
        lastSourceSize = source ? source->m_size : Vector2D{};
        lastSourceType = source ? source->m_type : Render::TEXTURE_INVALID;
        lastSourceTransform = source ? source->m_transform : HYPRUTILS_TRANSFORM_NORMAL;
        dirty = false;
        g_pHyprRenderer->damageBox(previous);
        previous = damageCursor();
        g_pHyprRenderer->damageBox(previous);
    }
    if (!glow) return;
    auto box = Pointer::mgr()->getCursorBoxGlobal();
    const double sx = box.w / sourceW, sy = box.h / sourceH;
    box.x -= PAD * sx; box.y -= PAD * sy;
    box.w += 2 * PAD * sx; box.h += 2 * PAD * sy;
    box.translate(-monitor->m_position).scale(monitor->m_scale).round();
    CTexPassElement::SRenderData data;
    data.tex = glow;
    data.box = box;
    g_pHyprRenderer->m_renderPass.add(makeUnique<CTexPassElement>(std::move(data)));
}
}

APICALL EXPORT std::string PLUGIN_API_VERSION() { return HYPRLAND_API_VERSION; }
APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE h) {
    if (HyprlandAPI::getHyprlandVersion(h).hash != GIT_COMMIT_HASH) throw std::runtime_error("hyprhand outline: Hyprland version mismatch");
    const char* serverHash = __hyprland_api_get_hash();
    if (!serverHash || std::strcmp(serverHash, __hyprland_api_get_client_hash()) != 0)
        throw std::runtime_error("hyprhand outline: Hyprland dependency ABI hash mismatch");
    if (!g_pHyprRenderer || g_pHyprRenderer->type() != Render::IHyprRenderer::RT_GL || !Render::GL::g_pHyprOpenGL ||
        Render::GL::g_pHyprOpenGL->m_eglContextVersion < Render::GL::CHyprOpenGLImpl::EGL_CONTEXT_GLES_3_0)
        throw std::runtime_error("hyprhand outline: OpenGL ES 3 renderer required");
    handle = h;
    try {
        if (!HyprlandAPI::addDispatcherV2(h, "hyprhand:outline", [](std::string path) -> SDispatchResult {
            if (path == "stop") { deactivate(); return {}; }
            if (!timer) return {.success = false, .error = "Outline timer unavailable; reload in the disposable test session"};
            const std::filesystem::path p(path);
            const char* runtime = getenv("XDG_RUNTIME_DIR");
            struct stat dir{};
            if (!runtime || !p.is_absolute() || p.filename() != "enabled" || p.parent_path().parent_path() != runtime ||
                !p.parent_path().filename().string().starts_with("hyprhand-") ||
                lstat(p.parent_path().c_str(), &dir) != 0 || !S_ISDIR(dir.st_mode) || dir.st_uid != getuid() || (dir.st_mode & 077))
                return {.success = false, .error = "Invalid hyprhand control path"};
            const auto value = readToken(path);
            if (value.empty()) return {.success = false, .error = "Control token unavailable"};
            deactivate();
            controlPath = path; token = value; active = true; dirty = true;
            previous = damageCursor();
            g_pHyprRenderer->damageBox(previous);
            return {};
        })) throw std::runtime_error("hyprhand outline: dispatcher registration failed");
        dispatcherRegistered = true;
        renderListener = Event::bus()->m_events.render.stage.listen([](eRenderStage stage) {
            try { render(stage); } catch (...) { deactivate(); }
        });
        shapeListener = Pointer::mgr()->m_events.cursorChanged.listen([] {
            try { invalidate(); } catch (...) { deactivate(); }
        });
        timer = wl_event_loop_add_timer(wl_display_get_event_loop(g_pCompositor->m_wlDisplay), [](void* data) -> int {
            try { return tick(data); } catch (...) { stopTimer(); deactivate(); return 0; }
        }, nullptr);
        if (!timer) throw std::runtime_error("hyprhand outline: timer unavailable");
        if (wl_event_source_timer_update(timer, 20) < 0) throw std::runtime_error("hyprhand outline: timer scheduling failed");
        return {"hyprhand-outline", "Blue glow from the real cursor alpha mask", "hyprhand", "0.1-experimental"};
    } catch (...) {
        // Hyprland ejects a failed init without calling PLUGIN_EXIT.
        cleanup();
        throw;
    }
}
APICALL EXPORT void PLUGIN_EXIT() {
    cleanup();
}
