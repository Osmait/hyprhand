const version = @import("../version.zig");

pub const text = "hyprhand " ++ version.string ++ " — computer use for Hyprland (Zig 0.16, Linux)\n" ++
    \\
    \\All commands accept --session NAME (default host). Input REQUIRES it.
    \\JSON output; events emits NDJSON. No MCP server or AI model.
    \\
    \\Observe and inspect:
    \\  doctor | state | monitors | windows | workspaces | sessions
    \\  observe [--monitor NAME] [--scale 0.1..2] [--backend auto|helper]
    \\  accessibility [--window ADDRESS] [--depth 5] [--limit 100] [--timeout-ms 5000]
    \\  wait stable [--pixels] [--monitor NAME] [--stable-ms 300] [--timeout-ms 5000]
    \\  wait window --class CLASS [--timeout-ms 5000]
    \\  wait focus --window ADDRESS | wait workspace --workspace NUMBER
    \\  events [--limit 100] [--timeout-ms 5000]
    \\  logs [--limit 100]
    \\  gc [--older-than-ms 300000] [--dry-run]
    \\
    \\Input (shared human cursor/focus ONLY in host; disabled until enable):
    \\  enable [--indicator none|outline] | stop
    \\  focus ADDRESS | workspace NUMBER
    \\  move --frame ID --x X --y Y
    \\  click|doubleclick --frame ID --x X --y Y [--button left|right|middle]
    \\  drag --frame ID --x X --y Y --to-x X --to-y Y [--duration-ms 500]
    \\  scroll --frame ID --x X --y Y [--dy STEPS] [--dx STEPS]
    \\    [--scroll-mode auto|wheel|continuous] [--duration-ms 500]
    \\  type --window ADDRESS --text TEXT [--backend auto|native|helper]
    \\  key CHORD --window ADDRESS [--backend auto|native|helper]
    \\
    \\Managed sessions (input isolation, NOT filesystem/credential sandboxing):
    \\  session create NAME [--nested] [--lua]
    \\    [--headless-bridge /absolute/trusted.so] Experimental, new headless only
    \\  session inspect NAME
    \\  session destroy NAME       Closes tracked apps; retains profiles and logs
    \\  launch --session NAME -- PROGRAM ARGUMENTS...
    \\  preview --session NAME [--monitor NAME] [--fps 1..15]
    \\    Maximum capture rate; unchanged images back off to 1 fps.
    \\    Optional GTK4 host PiP; read-only, close leaves agent running.
    \\
    \\Input accepts --dry-run. Coordinates are screenshot pixels, not desktop pixels.
    \\Pointer approach is smooth (auto 200..600ms); --move-duration-ms 50..10000
    \\overrides it for move/click/doubleclick/scroll/drag. Use 0 for instant approach.
    \\Drag --duration-ms controls the separate, smooth button-held segment.
    \\Scroll mode and pacing are independent; auto keeps legacy behavior.
    \\Wheel supports smooth pacing; continuous is unavailable on XWayland.
    \\Pointer actions accept --window ADDRESS and guard initial focus/layout.
    \\Focus the destination window before observing; changes during approach abort.
    \\Outline requires the optional Hyprland plugin, never auto-loaded.
    \\Pointer actions show a blue, click-through halo; --no-aura disables it.
    \\Frames expire after 30s or layout/focus changes. Observe again after each action.
    \\Type/key require the exact focused window. Example chord: ctrl+shift+Return.
    \\SIGINT/SIGTERM/stop cancel input; native devices release owned keys/buttons.
    \\Headless needs compatible GPU buffers. --nested opens a compositor preview.
    \\
;
