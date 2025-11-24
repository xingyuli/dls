const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "dls",
        .root_module = main_mod,
    });

    b.installArtifact(exe);

    // external dependencies
    const zbor_dep = b.dependency("zbor", .{
        .target = target,
        .optimize = optimize,
    });
    const zbor_mod = zbor_dep.module("zbor");

    exe.root_module.addImport("zbor", zbor_mod);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    setupTest(b, target, optimize, main_mod, zbor_mod);
}

fn setupTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    main_mod: *std.Build.Module,
    zbor_mod: *std.Build.Module,
) void {
    const model_mod = b.createModule(.{
        .root_source_file = b.path("src/model.zig"),
        .target = target,
        .optimize = optimize,
    });
    model_mod.addImport("zbor", zbor_mod);

    const memtable_mod = b.createModule(.{
        .root_source_file = b.path("src/memtable.zig"),
        .target = target,
        .optimize = optimize,
    });
    memtable_mod.addImport("zbor", zbor_mod);

    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_mod.addImport("zbor", zbor_mod);

    const main_unit_tests = b.addTest(.{ .root_module = main_mod });
    const run_main_unit_tests = b.addRunArtifact(main_unit_tests);

    const model_unit_tests = b.addTest(.{ .root_module = model_mod });
    const run_model_unit_tests = b.addRunArtifact(model_unit_tests);

    const memtable_unit_tests = b.addTest(.{ .root_module = memtable_mod });
    const run_memtable_unit_tests = b.addRunArtifact(memtable_unit_tests);

    const server_unit_tests = b.addTest(.{ .root_module = server_mod });
    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    // Main test step that runs ALL tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_main_unit_tests.step);
    test_step.dependOn(&run_model_unit_tests.step);
    test_step.dependOn(&run_memtable_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);

    const test_model_step = b.step("test-model", "Run model tests");
    test_model_step.dependOn(&run_model_unit_tests.step);

    const test_memtable_step = b.step("test-memtable", "Run memtable tests");
    test_memtable_step.dependOn(&run_memtable_unit_tests.step);

    const test_server_step = b.step("test-server", "Run server tests");
    test_server_step.dependOn(&run_server_unit_tests.step);
}
