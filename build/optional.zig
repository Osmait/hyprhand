//! Explicit opt-in artifacts. Defining steps never installs or loads them.
const std = @import("std");

pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/pip_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.linkSystemLibrary("gtk4", .{});
    module.addIncludePath(b.path("src/preview"));
    module.addCSourceFile(.{ .file = b.path("src/preview/pip_gtk_check.c"), .flags = &.{"-std=c11"} });
    const pip = b.addExecutable(.{ .name = "deskctl-pip", .root_module = module });
    const install = b.addInstallArtifact(pip, .{});
    b.step("pip", "Build optional read-only GTK4 session preview").dependOn(&install.step);
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/pip_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_module.linkSystemLibrary("gtk4", .{});
    test_module.addIncludePath(b.path("src/preview"));
    test_module.addCSourceFile(.{ .file = b.path("src/preview/pip_gtk_check.c"), .flags = &.{"-std=c11"} });
    const pip_tests = b.addTest(.{ .root_module = test_module });
    b.step("pip-test", "Test bounded preview transport/decoding without a display").dependOn(&b.addRunArtifact(pip_tests).step);

    bridge(b, "cursor-plugin", "cursor-outline", "plugin.cpp", "deskctl-outline.so", "Build optional experimental Hyprland 0.56.2 outline bridge (never loads it)");
    bridge(b, "headless-bridge", "headless-formats", "bridge.cpp", "deskctl-headless-formats.so", "Build optional Aquamarine 0.15.0 format bridge (never loads it)");
}

fn bridge(b: *std.Build, step: []const u8, directory: []const u8, source: []const u8, library: []const u8, description: []const u8) void {
    const command = b.addSystemCommand(&.{"sh"});
    // Headers/ABI can change outside Zig's dependency graph. Always check them.
    command.has_side_effects = true;
    command.addFileArg(b.path(b.fmt("experimental/{s}/build.sh", .{directory})));
    command.addFileArg(b.path(b.fmt("experimental/{s}/{s}", .{ directory, source })));
    const so = command.addOutputFileArg(library);
    const metadata_name = b.fmt("{s}.build-metadata", .{library});
    const install = b.addInstallFileWithDir(so, .lib, library);
    const metadata = b.addInstallFileWithDir(so.dirname().path(b, metadata_name), .lib, metadata_name);
    install.step.dependOn(&metadata.step);
    b.step(step, description).dependOn(&install.step);
}
