const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "maccy-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_clipboard.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_paste.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_hotkey.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/macos_app.m"), .flags = &.{"-fobjc-arc"} });
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("ApplicationServices", .{});
    exe.root_module.linkFramework("Carbon", .{});
    exe.root_module.linkSystemLibrary("sqlite3", .{});
    exe.root_module.linkSystemLibrary("c", .{});
    b.installArtifact(exe);

    const run_step = b.step("run", "Run maccy-zig");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const coverage_test_install = b.addInstallArtifact(tests, .{
        .dest_dir = .{ .override = .{ .custom = "coverage" } },
        .dest_sub_path = "maccy-zig-test",
    });
    const coverage_test_step = b.step("coverage-test-bin", "Build the test binary used by coverage tooling");
    coverage_test_step.dependOn(&coverage_test_install.step);

    const coverage_cmd = b.addSystemCommand(&.{
        "scripts/coverage.sh",
        "--backend=xcode-llvm",
        "--min-line-rate=0.90",
    });
    coverage_cmd.step.dependOn(&coverage_test_install.step);
    const coverage_step = b.step("coverage-report", "Run coverage tooling for the Zig allowlist");
    coverage_step.dependOn(&coverage_cmd.step);
}
