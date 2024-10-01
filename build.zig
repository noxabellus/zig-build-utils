const std = @import("std");
const Build = std.Build;

pub const Module = @import("src/root.zig");

pub fn build(b: *Build) !void {
    const defaultTarget = b.standardTargetOptions(.{});
    const defaultOptimize = b.standardOptimizeOption(.{});


    const Templater = b.addExecutable(.{
        .name = "templater",
        .root_source_file = b.path("src/bin/Templater.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const LibJoiner = b.addExecutable(.{
        .name = "libjoiner",
        .root_source_file = b.path("src/bin/LibJoiner.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    _ = b.addModule("HeaderGenUtils", .{
        .root_source_file = b.path("src/HeaderGenUtils.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    _ = b.addModule("Manifest", .{
        .root_source_file = b.path("src/Manifest.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const Snapshot = b.addModule("Snapshot", .{
        .root_source_file = b.path("src/Snapshot.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    const SnapshotWriter = b.addExecutable(.{
        .name = "snapshot-writer",
        .root_source_file = b.path("src/bin/SnapshotWriter.zig"),
        .target = defaultTarget,
        .optimize = defaultOptimize,
    });

    SnapshotWriter.root_module.addImport("Snapshot", Snapshot);

    b.default_step.dependOn(&b.addInstallArtifact(SnapshotWriter, .{}).step);
    b.default_step.dependOn(&b.addInstallArtifact(Templater, .{}).step);
    b.default_step.dependOn(&b.addInstallArtifact(LibJoiner, .{}).step);
    b.default_step.dependOn(&b.addInstallFile(Module.makeHeaderGenSource(b), "HeaderGen.zig").step);
}
