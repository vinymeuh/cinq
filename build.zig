const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const cinq = b.addExecutable(.{
        .name = "cinq",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(cinq);

    const cinq_run_exe = b.addRunArtifact(cinq);
    cinq_run_exe.step.dependOn(b.getInstallStep());
    const cinq_run_step = b.step("run", "Run cinq");
    cinq_run_step.dependOn(&cinq_run_exe.step);
}
