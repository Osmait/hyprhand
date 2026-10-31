const std = @import("std");
const builtin = @import("builtin");
const native = @import("build/native.zig");
const optional = @import("build/optional.zig");

comptime {
    if (builtin.zig_version.major != 0) @compileError("hyprhand requires Zig 0.17.x");
    if (builtin.zig_version.minor != 17) @compileError("hyprhand requires Zig 0.17.x");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.configure(b, module, target, optimize);
    const executable = b.addExecutable(.{ .name = "hyprhand", .root_module = module });
    b.installArtifact(executable);
    b.installFile(
        "completions/hyprhand.bash",
        "share/bash-completion/completions/hyprhand",
    );
    b.installFile(
        "completions/hyprhand.fish",
        "share/fish/vendor_completions.d/hyprhand.fish",
    );
    b.installDirectory(.{
        .source_dir = b.path("skills/hyprhand"),
        .install_dir = .prefix,
        .install_subdir = "share/hyprhand/skills/hyprhand",
    });
    optional.add(b, target, optimize);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run hyprhand").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const unit_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests (no desktop input)").dependOn(&unit_tests.step);

    const integration = b.addSystemCommand(&.{"env"});
    integration.addPrefixedArtifactArg("HYPRHAND_TEST_BIN=", executable);
    integration.addArgs(&.{ "python3", "tests/integration.py" });
    integration.step.dependOn(b.getInstallStep());
    b.step(
        "integration",
        "Run fake-compositor CLI tests (no desktop input)",
    ).dependOn(&integration.step);

    const format = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "build.zig",
        "build",
        "src",
    });
    b.step(
        "fmt-check",
        "Check Zig formatting without modifying files",
    ).dependOn(&format.step);
    const checks = b.addSystemCommand(&.{"env"});
    checks.addPrefixedArtifactArg("HYPRHAND_TEST_BIN=", executable);
    checks.addArgs(&.{ "python3", "scripts/check.py" });
    checks.step.dependOn(b.getInstallStep());
    checks.step.dependOn(&unit_tests.step);
    checks.step.dependOn(&format.step);
    b.step(
        "check",
        "Run formatting, unit and all offline regression suites (no desktop input)",
    ).dependOn(&checks.step);
}
