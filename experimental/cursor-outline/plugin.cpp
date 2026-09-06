// Optional Hyprland 0.56.2 bridge. The CLI and input backends remain Zig.
// Never auto-loaded: first validate this against a disposable compositor.
#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/pointer/PointerManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/render/pass/TexPassElement.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cmath>
#include <array>
#include <filesystem>
#include <stdexcept>

namespace {
HANDLE handle;
wl_event_source* timer = nullptr;
CHyprSignalListener renderListener, shapeListener;
std::string controlPath, token;
bool active = false, dirty = true;
CBox previous;
SP<Render::ITexture> glow;
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
    if (active) g_pHyprRenderer->damageBox(previous);
    active = false;
    controlPath.clear();
    token.clear();
    dirty = true;
    // GL texture lifetime is handled in the next render callback or unload.
}

int tick(void*) {
    if (active) {
        if (readToken(controlPath) != token) deactivate();
        else {
            const auto box = damageCursor();
            if (dirty || box.x != previous.x || box.y != previous.y || box.w != previous.w || box.h != previous.h) {
                g_pHyprRenderer->damageBox(previous);
                g_pHyprRenderer->damageBox(box);
                previous = box;
            }
        }
    }
    wl_event_source_timer_update(timer, 20);
    return 0;
}

bool makeGlow(const SP<Render::ITexture>& source) {
    glow.reset();
    if (!source || source->m_type != Render::TEXTURE_RGBA || source->m_texID == 0) return false;
    const int w = source->m_size.x, h = source->m_size.y;
    if (w < 1 || h < 1 || w > 256 || h > 256) return false;
    std::vector<uint8_t> pixels(w * h * 4);
    GLint oldRead = 0, oldPack = 0;
    GLuint fbo = 0;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &oldRead);
    glGetIntegerv(GL_PACK_ALIGNMENT, &oldPack);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, source->m_texID, 0);
    const bool complete = glCheckFramebufferStatus(GL_READ_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE;
    if (complete) {
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pixels.data());
    }
    glPixelStorei(GL_PACK_ALIGNMENT, oldPack);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, oldRead);
    glDeleteFramebuffers(1, &fbo);
    if (!complete) return false;
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
    sourceW = w; sourceH = h;
    return !!glow;
}

void render(eRenderStage stage) {
    if (stage != RENDER_LAST_MOMENT || !active) return;
    if (readToken(controlPath) != token) { deactivate(); return; }
    if (!g_pHyprRenderer->shouldRenderCursor()) return;
    const auto monitor = g_pHyprRenderer->renderData().pMonitor.lock();
    if (!monitor) return;
    if (dirty) {
        makeGlow(Pointer::mgr()->getCurrentCursorTexture());
        dirty = false;
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
    handle = h;
    if (HyprlandAPI::getHyprlandVersion(h).hash != GIT_COMMIT_HASH) throw std::runtime_error("deskctl outline: Hyprland version mismatch");
    if (g_pHyprRenderer->type() != Render::IHyprRenderer::RT_GL) throw std::runtime_error("deskctl outline: OpenGL renderer required");
    if (!HyprlandAPI::addDispatcherV2(h, "deskctl:outline", [](std::string path) -> SDispatchResult {
        if (path == "stop") { deactivate(); return {}; }
        const std::filesystem::path p(path);
        const char* runtime = getenv("XDG_RUNTIME_DIR");
        struct stat dir{};
        if (!runtime || !p.is_absolute() || p.filename() != "enabled" || p.parent_path().parent_path() != runtime ||
            !p.parent_path().filename().string().starts_with("deskctl-") ||
            lstat(p.parent_path().c_str(), &dir) != 0 || !S_ISDIR(dir.st_mode) || dir.st_uid != getuid() || (dir.st_mode & 077))
            return {.success = false, .error = "Invalid deskctl control path"};
        const auto value = readToken(path);
        if (value.empty()) return {.success = false, .error = "Control token unavailable"};
        controlPath = path; token = value; active = true; dirty = true;
        previous = damageCursor();
        g_pHyprRenderer->damageBox(previous);
        return {};
    })) throw std::runtime_error("deskctl outline: dispatcher registration failed");
    renderListener = Event::bus()->m_events.render.stage.listen(render);
    shapeListener = Pointer::mgr()->m_events.cursorChanged.listen([] { dirty = true; });
    timer = wl_event_loop_add_timer(wl_display_get_event_loop(g_pCompositor->m_wlDisplay), tick, nullptr);
    if (!timer) throw std::runtime_error("deskctl outline: timer unavailable");
    wl_event_source_timer_update(timer, 20);
    return {"deskctl-outline", "Blue glow from the real cursor alpha mask", "deskctl", "0.1-experimental"};
}
APICALL EXPORT void PLUGIN_EXIT() {
    deactivate();
    if (timer) wl_event_source_remove(timer);
    timer = nullptr;
    renderListener.reset(); shapeListener.reset();
    glow.reset();
}
