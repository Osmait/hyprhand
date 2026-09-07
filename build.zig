const std = @import("std");
const builtin = @import("builtin");
const native = @import("build/native.zig");
const optional = @import("build/optional.zig");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16)
        @compileError("deskctl requires Zig 0.16.x");
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
    native.configure(b, module);
    const exe = b.addExecutable(.{ .name = "deskctl", .root_module = module });
    b.installArtifact(exe);
    b.installFile("completions/deskctl.bash", "share/bash-completion/completions/deskctl");
    b.installFile("completions/deskctl.fish", "share/fish/vendor_completions.d/deskctl.fish");
    b.installDirectory(.{ .source_dir = b.path("skills/deskctl"), .install_dir = .prefix, .install_subdir = "share/deskctl/skills/deskctl" });
    optional.add(b, target, optimize);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run deskctl").dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = module });
    const unit = b.addRunArtifact(tests);
    b.step("test", "Run unit tests (no desktop input)").dependOn(&unit.step);

    const integration = b.addSystemCommand(&.{ "python3", "tests/integration.py" });
    integration.setEnvironmentVariable("DESKCTL_TEST_BIN", b.getInstallPath(.bin, "deskctl"));
    integration.step.dependOn(b.getInstallStep());
    b.step("integration", "Run fake-compositor CLI tests (no desktop input)").dependOn(&integration.step);

    const format = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "build.zig", "build", "src" });
    b.step("fmt-check", "Check Zig formatting without modifying files").dependOn(&format.step);
    const checks = b.addSystemCommand(&.{ "python3", "scripts/check.py" });
    checks.setEnvironmentVariable("DESKCTL_TEST_BIN", b.getInstallPath(.bin, "deskctl"));
    checks.step.dependOn(b.getInstallStep());
    checks.step.dependOn(&unit.step);
    checks.step.dependOn(&format.step);
    b.step("check", "Run formatting, unit and all offline regression suites (no desktop input)").dependOn(&checks.step);
}
