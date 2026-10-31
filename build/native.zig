//! Native dependencies of the CLI only; GTK belongs to the optional viewer.
const std = @import("std");

pub fn configure(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const native_c = b.addTranslateC(.{
        .root_source_file = b.path("src/platform/native_c.h"),
        .target = target,
        .optimize = optimize,
    });
    const protocols = .{
        .{ "wlr-virtual-pointer-unstable-v1", "virtual-pointer" },
        .{ "virtual-keyboard-unstable-v1", "virtual-keyboard" },
        .{ "wlr-layer-shell-unstable-v1", "layer-shell" },
        .{ "ext-image-copy-capture-v1", "ext-image-copy-capture-v1" },
        .{ "ext-image-capture-source-v1", "ext-image-capture-source-v1" },
        .{ "ext-foreign-toplevel-list-v1", "ext-foreign-toplevel-list-v1" },
    };
    inline for (protocols) |protocol| {
        const source = b.path(b.fmt("protocols/{s}.xml", .{protocol[0]}));
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header.addFileArg(source);
        const header_file = header.addOutputFileArg(b.fmt("{s}.h", .{protocol[1]}));
        module.addIncludePath(header_file.dirname());
        native_c.addIncludePath(header_file.dirname());
        add_protocol_code(b, module, source, protocol[1]);
    }
    // Layer shell refers to xdg_popup even though hyprhand creates no popups.
    add_protocol_code(b, module, b.path("protocols/xdg-shell.xml"), "xdg-shell");
    for ([_][]const u8{ "wayland-client", "xkbcommon", "atspi-2", "gobject-2.0" }) |library| {
        module.linkSystemLibrary(library, .{});
    }
    for ([_][]const u8{ "wayland-client", "xkbcommon" }) |library| {
        native_c.linkSystemLibrary(library, .{});
    }
    module.addImport("native_c", native_c.createModule());

    const accessibility_c = b.addTranslateC(.{
        .root_source_file = b.path("src/accessibility/accessibility.h"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("accessibility_c", accessibility_c.createModule());
    module.addIncludePath(b.path("src/accessibility"));
    module.addCSourceFile(.{
        .file = b.path("src/accessibility/accessibility.c"),
        .flags = &.{"-std=c11"},
    });
}

fn add_protocol_code(
    b: *std.Build,
    module: *std.Build.Module,
    source: std.Build.LazyPath,
    name: []const u8,
) void {
    const scanner = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    scanner.addFileArg(source);
    const code = scanner.addOutputFileArg(b.fmt("{s}.c", .{name}));
    module.addCSourceFile(.{ .file = code, .flags = &.{} });
}
