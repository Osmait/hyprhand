# Preview surface contract

Mode: Operate. The owner monitors a managed session while using the host.
Success: recognize current activity and stop deskctl input with one explicit
action, without giving the agent host focus or input.

User revision: borderless image-first PiP, controls integrated over the image.
No separate title/footer bars, compositor border, rounding or shadow. Full-window
contain-fit image, top session identity and close, bottom status/stop plus a
resize grip. Dark gradient scrims protect white labels over arbitrary imagery.
Default 640 × 360, minimum 360 × 203; dragging the image moves the window.
Keep close/stop permanently reachable and keyboard focus visible. No input relay.

States: connecting, live/control enabled, live/control stopped, stopping,
stop failed, disconnected/locked. Clear stale pixels; retry without reconnecting
to a different compositor instance. Close means viewer only.

The design skill's web/mobile tooling does not cover this Linux-native surface;
validate the working GTK component directly with desktop screenshots.
