const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Since we can't parse json at comptime, build and run this to
    // parse json and output a binary format that we can parse at comptime
    const resource_gen = b.addExecutable(.{
        .name = "resource_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/resource_gen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    resource_gen.root_module.addAnonymousImport(
        "assets/spritesheet.json",
        .{ .root_source_file = b.path("assets/spritesheet.json") },
    );
    const run_resource_gen = b.addRunArtifact(resource_gen);
    const out_path = b.path("assets/spritesheet.bin");
    run_resource_gen.addArg(out_path.getPath(b));

    const exe = b.addExecutable(.{
        .name = "in_deep_ship",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addAnonymousImport(
        "assets/spritesheet.bin",
        .{ .root_source_file = b.path("assets/spritesheet.bin") },
    );
    exe.step.dependOn(&run_resource_gen.step);
    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
