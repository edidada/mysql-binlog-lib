const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mysqlbinlog-zig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    const unit = b.addTest(.{
        .root_source_file = b.path("src/parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run unit + golden tests");
    test_step.dependOn(&run_unit.step);
}
