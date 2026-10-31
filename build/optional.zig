//! Explicit opt-in artifacts. Defining steps never installs or loads them.
const std = @import("std");

pub fn add(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/pip_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const gtk_c = b.addTranslateC(.{
        .root_source_file = b.path("src/preview/gtk_c.h"),
        .target = target,
        .optimize = optimize,
    });
    gtk_c.addIncludePath(b.path("src/preview"));
    const gtk_module = gtk_c.createModule();
    module.addImport("gtk_c", gtk_module);
    module.linkSystemLibrary("gtk4", .{});
    module.addIncludePath(b.path("src/preview"));
    module.addCSourceFile(.{
        .file = b.path("src/preview/pip_gtk_check.c"),
        .flags = &.{"-std=c11"},
    });
    const pip = b.addExecutable(.{ .name = "hyprhand-pip", .root_module = module });
    const install = b.addInstallArtifact(pip, .{});
    b.step("pip", "Build optional read-only GTK4 session preview").dependOn(&install.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/pip_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.addImport("gtk_c", gtk_module);
    test_module.linkSystemLibrary("gtk4", .{});
    test_module.addIncludePath(b.path("src/preview"));
    test_module.addCSourceFile(.{
        .file = b.path("src/preview/pip_gtk_check.c"),
        .flags = &.{"-std=c11"},
    });
    const pip_tests = b.addTest(.{ .root_module = test_module });
    b.step(
        "pip-test",
        "Test bounded preview transport/decoding without a display",
    ).dependOn(&b.addRunArtifact(pip_tests).step);

    add_experimental_bridge(b, .{
        .step = "cursor-plugin",
        .directory = "cursor-outline",
        .source = "plugin.cpp",
        .library = "hyprhand-outline.so",
        .description = "Build optional experimental Hyprland 0.56.2 outline bridge " ++
            "(never loads it)",
    });
    add_experimental_bridge(b, .{
        .step = "headless-bridge",
        .directory = "headless-formats",
        .source = "bridge.cpp",
        .library = "hyprhand-headless-formats.so",
        .description = "Build optional Aquamarine 0.15.x format bridge (never loads it)",
    });
}

const Bridge = struct {
    step: []const u8,
    directory: []const u8,
    source: []const u8,
    library: []const u8,
    description: []const u8,
};

fn add_experimental_bridge(b: *std.Build, bridge: Bridge) void {
    const command = b.addSystemCommand(&.{"sh"});
    // Headers/ABI can change outside Zig's dependency graph. Always check them.
    command.has_side_effects = true;
    command.addFileArg(b.path(b.fmt("experimental/{s}/build.sh", .{bridge.directory})));
    command.addFileArg(b.path(b.fmt(
        "experimental/{s}/{s}",
        .{ bridge.directory, bridge.source },
    )));
    const library_file = command.addOutputFileArg(bridge.library);
    const metadata_name = b.fmt("{s}.build-metadata", .{bridge.library});
    const install = b.addInstallFileWithDir(library_file, .lib, bridge.library);
    const metadata = b.addInstallFileWithDir(
        library_file.dirname().path(b, metadata_name),
        .lib,
        metadata_name,
    );
    install.step.dependOn(&metadata.step);
    b.step(bridge.step, bridge.description).dependOn(&install.step);
}
