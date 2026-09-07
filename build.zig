const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16)
        @compileError("deskctl requires Zig 0.16.x");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pip_module = b.createModule(.{
        .root_source_file = b.path("src/pip.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pip_module.linkSystemLibrary("gtk4", .{});
    pip_module.addIncludePath(b.path("src"));
    pip_module.addCSourceFile(.{ .file = b.path("src/pip_gtk_check.c"), .flags = &.{"-std=c11"} });
    const pip = b.addExecutable(.{ .name = "deskctl-pip", .root_module = pip_module });
    const install_pip = b.addInstallArtifact(pip, .{});
    b.step("pip", "Build optional read-only GTK4 session preview").dependOn(&install_pip.step);
    const plugin = b.addSystemCommand(&.{"sh"});
    // System headers/ABI may change outside Zig's dependency graph. Always
    // rerun these explicit optional builds, including the version checks.
    plugin.has_side_effects = true;
    plugin.addFileArg(b.path("experimental/cursor-outline/build.sh"));
    plugin.addFileArg(b.path("experimental/cursor-outline/plugin.cpp"));
    const so = plugin.addOutputFileArg("deskctl-outline.so");
    const install_plugin = b.addInstallFileWithDir(so, .lib, "deskctl-outline.so");
    const install_plugin_metadata = b.addInstallFileWithDir(so.dirname().path(b, "deskctl-outline.so.build-metadata"), .lib, "deskctl-outline.so.build-metadata");
    install_plugin.step.dependOn(&install_plugin_metadata.step);
    b.step("cursor-plugin", "Build optional experimental Hyprland 0.56.2 outline bridge (never loads it)").dependOn(&install_plugin.step);
    const headless = b.addSystemCommand(&.{"sh"});
    headless.has_side_effects = true;
    headless.addFileArg(b.path("experimental/headless-formats/build.sh"));
    headless.addFileArg(b.path("experimental/headless-formats/bridge.cpp"));
    const headless_so = headless.addOutputFileArg("deskctl-headless-formats.so");
    const install_headless = b.addInstallFileWithDir(headless_so, .lib, "deskctl-headless-formats.so");
    const install_headless_metadata = b.addInstallFileWithDir(headless_so.dirname().path(b, "deskctl-headless-formats.so.build-metadata"), .lib, "deskctl-headless-formats.so.build-metadata");
    install_headless.step.dependOn(&install_headless_metadata.step);
    b.step("headless-bridge", "Build optional Aquamarine 0.15.0 format bridge (never loads it)").dependOn(&install_headless.step);
    const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    header.addFileArg(b.path("protocols/wlr-virtual-pointer-unstable-v1.xml"));
    const h = header.addOutputFileArg("virtual-pointer.h");
    const code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    code.addFileArg(b.path("protocols/wlr-virtual-pointer-unstable-v1.xml"));
    const c = code.addOutputFileArg("virtual-pointer.c");
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addIncludePath(h.dirname());
    module.addCSourceFile(.{ .file = c, .flags = &.{} });
    const keyboard_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    keyboard_header.addFileArg(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
    const kh = keyboard_header.addOutputFileArg("virtual-keyboard.h");
    const keyboard_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    keyboard_code.addFileArg(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
    const kc = keyboard_code.addOutputFileArg("virtual-keyboard.c");
    module.addIncludePath(kh.dirname());
    module.addCSourceFile(.{ .file = kc, .flags = &.{} });
    const layer_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    layer_header.addFileArg(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    const lh = layer_header.addOutputFileArg("layer-shell.h");
    const layer_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    layer_code.addFileArg(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    const lc = layer_code.addOutputFileArg("layer-shell.c");
    // Layer shell's get_popup signature refers to xdg_popup, even though the
    // halo never creates a popup. Supply the upstream protocol interface data.
    const xdg_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    xdg_code.addFileArg(b.path("protocols/xdg-shell.xml"));
    const xc = xdg_code.addOutputFileArg("xdg-shell.c");
    module.addIncludePath(lh.dirname());
    module.addCSourceFile(.{ .file = lc, .flags = &.{} });
    module.addCSourceFile(.{ .file = xc, .flags = &.{} });
    for ([_][]const u8{ "ext-image-copy-capture-v1", "ext-image-capture-source-v1", "ext-foreign-toplevel-list-v1" }) |protocol| {
        const source = b.path(b.fmt("protocols/{s}.xml", .{protocol}));
        const capture_header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        capture_header.addFileArg(source);
        const ch = capture_header.addOutputFileArg(b.fmt("{s}.h", .{protocol}));
        const capture_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        capture_code.addFileArg(source);
        const cc = capture_code.addOutputFileArg(b.fmt("{s}.c", .{protocol}));
        module.addIncludePath(ch.dirname());
        module.addCSourceFile(.{ .file = cc, .flags = &.{} });
    }
    module.linkSystemLibrary("wayland-client", .{});
    module.linkSystemLibrary("xkbcommon", .{});
    module.linkSystemLibrary("atspi-2", .{});
    module.linkSystemLibrary("gobject-2.0", .{});
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{ .file = b.path("src/accessibility.c"), .flags = &.{"-std=c11"} });
    const exe = b.addExecutable(.{ .name = "deskctl", .root_module = module });
    b.installArtifact(exe);
    b.installFile("completions/deskctl.bash", "share/bash-completion/completions/deskctl");
    b.installFile("completions/deskctl.fish", "share/fish/vendor_completions.d/deskctl.fish");
    b.installDirectory(.{ .source_dir = b.path("skills/deskctl"), .install_dir = .prefix, .install_subdir = "share/deskctl/skills/deskctl" });
    const integration = b.addSystemCommand(&.{ "python3", "tests/integration.py" });
    integration.setEnvironmentVariable("DESKCTL_TEST_BIN", b.getInstallPath(.bin, "deskctl"));
    integration.step.dependOn(b.getInstallStep());
    b.step("integration", "Run fake-compositor CLI tests (no desktop input)").dependOn(&integration.step);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run deskctl").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Run unit tests (no desktop input)").dependOn(&b.addRunArtifact(tests).step);
}
