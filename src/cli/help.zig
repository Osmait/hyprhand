const version = @import("../version.zig");

pub const text = "hyprhand " ++ version.string ++
    " — computer use for Hyprland (Zig 0.17, Linux)\n" ++
    \\
    \\All commands accept --session NAME (default host). Input REQUIRES it.
    \\JSON output; events emits NDJSON. No MCP server or AI model.
    \\
    \\Observe and inspect:
    \\  doctor | monitors | workspaces | sessions | state|windows [--compact]
    \\  observe [--monitor NAME | --window ADDRESS | --frame ID --x X --y Y --to-x X --to-y Y]
    \\    [--scale 0.1..2] [--max-edge PX] [--since FRAME_ID] [--retry 0..10] [--marks]
    \\    [--backend auto|helper]
    \\  cursor [--frame ID]
    \\  accessibility [--window ADDRESS [--interactive] [--frame ID]] [--depth 5]
    \\    [--limit 100] [--timeout-ms 5000]  With --window: refs @SNAP:eN, desktop
    \\    bounds, and frame_point (a --frame pixel ready for click)
    \\  wait stable [--pixels] [--monitor NAME] [--stable-ms 300] [--timeout-ms 5000]
    \\  wait window --class CLASS [--timeout-ms 5000]
    \\  wait focus --window ADDRESS | wait workspace --workspace NUMBER
    \\  events [--limit 100] [--timeout-ms 5000]
    \\  logs [--limit 100]
    \\  gc [--older-than-ms 300000] [--dry-run]
    \\
    \\Input (shared human cursor/focus ONLY in host; disabled until enable):
    \\  enable [--indicator none|outline] [--gate ask|human|off] | stop
    \\    Gate: pay/send/delete/sign-up/accept controls need --ack ID (ask), a host
    \\    notification answered by the human (human, managed only), or nothing (off)
    \\  focus ADDRESS | workspace NUMBER
    \\  move --frame ID --x X --y Y
    \\  click|doubleclick --frame ID (--x X --y Y | --mark N) [--button left|right|...]
    \\    click --count 1..3 (3 = triple click); --mods ctrl+shift holds modifiers
    \\    during click/doubleclick/drag/scroll (not on XWayland)
    \\  drag --frame ID --x X --y Y --to-x X --to-y Y [--duration-ms 500]
    \\  scroll --frame ID --x X --y Y [--dy STEPS] [--dx STEPS]
    \\    [--scroll-mode auto|wheel|continuous] [--duration-ms 500]
    \\  type --window ADDRESS --text TEXT [--backend auto|native|helper|clipboard]
    \\    clipboard: wl-copy into the session clipboard (kept) + ctrl+v; never host
    \\  key CHORD --window ADDRESS [--repeat 1..100] [--backend auto|native|helper]
    \\  act VERB --ref @SNAP:eN [--text VALUE]   Semantic AT-SPI action, no pointer:
    \\    click|focus|set-value|toggle|check|uncheck|expand|collapse|select|scroll-to
    \\    Verified by read-back where possible; ActionNotSupported means use the pointer.
    \\
    \\Managed sessions (input isolation; --sandbox adds file/credential isolation):
    \\  session create NAME [--nested] [--lua] [--sandbox [--offline]]
    \\    --sandbox: apps run in bwrap with a private HOME, no host sockets or
    \\    credentials; --offline: and no network
    \\    [--headless-bridge /absolute/trusted.so] Experimental, new headless only
    \\  session inspect NAME
    \\  session destroy NAME       Closes tracked apps; retains profiles and logs
    \\  launch --session NAME -- PROGRAM ARGUMENTS...
    \\  preview --session NAME [--monitor NAME] [--host-monitor NAME] [--fps 1..15]
    \\    --monitor is the session's monitor; --host-monitor places the PiP on the host.
    \\    Maximum capture rate; unchanged images back off to 1 fps.
    \\    Optional GTK4 host PiP; close leaves agent running. Take over lets the
    \\    human type (logins, captchas) while agent input is stopped; Return
    \\    restores it. state reports human_takeover and control_enabled.
    \\
    \\Input accepts --dry-run. Coordinates are screenshot pixels, not desktop pixels.
    \\Errors and input results carry disposition {delivery, retry_safe}: retry only
    \\when retry_safe is true; otherwise observe first.
    \\Input commands accept --then state|observe|accessibility [--settle-ms 250]:
    \\the response adds what that command would print after the action.
    \\dialect anthropic|openai|gemini --session S [--window W] [--max-edge PX]
    \\  [--ack ID] [--confirmed] < turn.json   A model's native computer-use calls
    \\  in, native results out, through every guard and the confirmation gate
    \\journal start NAME | stop | show NAME   Record input steps by window class,
    \\  element role/name and relative points (password text never stored)
    \\replay NAME --session S [--execute]    Plan, or re-resolve and run the steps
    \\  through the normal guards and gate, stopping at the first that fails
    \\sequence --session S [--then ...] [--dry-run] < steps.json  Runs a JSON array
    \\of input/wait command lines (no --session) in order, validated first,
    \\stopping at the first failure; reports each step's result and disposition.
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
    \\Headless needs compatible GPU buffers; on NVIDIA build the bridge
    \\(scripts/install.sh --with-bridge). --nested opens a compositor window.
    \\observe --retry N retries timeouts and stale frames N times, 0.7s apart.
    \\Fewer image tokens: --window crops to one window, --frame with a box zooms into
    \\an earlier frame, --max-edge caps the long side, and --since FRAME_ID reports
    \\changed:false when only a text cursor blinked, with a diff box otherwise.
    \\observe --window W --marks numbers the operable elements on marked_image_path;
    \\pointer commands accept --mark N of that frame instead of --x --y.
    \\state/windows --compact list windows in a fraction of the raw JSON.
    \\
;
