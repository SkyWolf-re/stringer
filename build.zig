const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_types = b.addModule("types", .{ .root_source_file = .{ .cwd_relative = "src/types.zig" } });
    const mod_emit = b.addModule("emit", .{ .root_source_file = .{ .cwd_relative = "src/emit.zig" } });
    const mod_detect_ascii = b.addModule("detect_ascii", .{ .root_source_file = .{ .cwd_relative = "src/detect_ascii.zig" } });
    const mod_detect_utf16 = b.addModule("detect_utf16", .{ .root_source_file = .{ .cwd_relative = "src/detect_utf16.zig" } });
    const mod_chunk = b.addModule("chunk", .{ .root_source_file = .{ .cwd_relative = "src/chunk.zig" } });
    const mod_io = b.addModule("io", .{ .root_source_file = .{ .cwd_relative = "src/io.zig" } });
    const mod_main = b.addModule("main", .{ .root_source_file = .{ .cwd_relative = "src/main.zig" } });

    //lowkey annoying that we need to put each import every time
    mod_emit.addImport("types", mod_types);

    mod_detect_ascii.addImport("types", mod_types);
    mod_detect_ascii.addImport("emit", mod_emit);

    mod_detect_utf16.addImport("types", mod_types);
    mod_detect_utf16.addImport("emit", mod_emit);

    mod_chunk.addImport("types", mod_types);
    mod_emit.addImport("types", mod_types);

    mod_detect_ascii.addImport("types", mod_types);
    mod_detect_ascii.addImport("emit", mod_emit);

    mod_detect_utf16.addImport("types", mod_types);
    mod_detect_utf16.addImport("emit", mod_emit);
    mod_detect_utf16.addImport("detect_ascii", mod_detect_ascii);

    // io has no deps right now

    const main_mod = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("types", mod_types);
    main_mod.addImport("emit", mod_emit);
    main_mod.addImport("detect_ascii", mod_detect_ascii);
    main_mod.addImport("detect_utf16", mod_detect_utf16);
    main_mod.addImport("chunk", mod_chunk);
    main_mod.addImport("io", mod_io);

    const exe = b.addExecutable(.{ .name = "stringer", .root_module = main_mod });
    exe.root_module.link_libc = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run stringer").dependOn(&run_cmd.step);

    const mod_test_helpers = b.addModule("test_helpers", .{
        .root_source_file = .{ .cwd_relative = "test/helpers.zig" },
    });

    const test_mod_utf16 = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_detect_utf16.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_mod_utf16.addImport("types", mod_types);
    test_mod_utf16.addImport("emit", mod_emit);
    test_mod_utf16.addImport("chunk", mod_chunk);
    test_mod_utf16.addImport("test_helpers", mod_test_helpers);
    test_mod_utf16.addImport("detect_utf16", mod_detect_utf16);

    const test_mod_ascii = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_detect_ascii.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_mod_ascii.addImport("types", mod_types);
    test_mod_ascii.addImport("emit", mod_emit);
    test_mod_ascii.addImport("chunk", mod_chunk);
    test_mod_ascii.addImport("test_helpers", mod_test_helpers);
    test_mod_ascii.addImport("detect_ascii", mod_detect_ascii);

    const test_emit = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_emit.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_emit.addImport("types", mod_types);
    test_emit.addImport("test_helpers", mod_test_helpers);
    test_emit.addImport("emit", mod_emit);

    const test_chunk = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_chunk.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_chunk.addImport("types", mod_types);
    test_chunk.addImport("chunk", mod_chunk);

    const test_io = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_io.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_io.addImport("io", mod_io);

    const test_cli = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_cli.zig" },
        .target = target,
        .optimize = optimize,
    });

    test_cli.addImport("types", mod_types);
    test_cli.addImport("main", mod_main);

    const t_utf16 = b.addTest(.{ .root_module = test_mod_utf16 });
    const run_utf16 = b.addRunArtifact(t_utf16);
    const t_ascii = b.addTest(.{ .root_module = test_mod_ascii });
    const run_ascii = b.addRunArtifact(t_ascii);
    const t_emit = b.addTest(.{ .root_module = test_emit });
    const run_emit = b.addRunArtifact(t_emit);
    const t_chunk = b.addTest(.{ .root_module = test_chunk });
    const run_chunk = b.addRunArtifact(t_chunk);
    const t_io = b.addTest(.{ .root_module = test_io });
    const run_io = b.addRunArtifact(t_io);
    const t_cli = b.addTest(.{ .root_module = test_cli });
    const run_cli = b.addRunArtifact(t_cli);

    //integration test
    run_cli.step.dependOn(&exe.step);
    const it_step = b.step("it-cli", "Run integration CLI tests");
    it_step.dependOn(&run_cli.step);

    const check = b.step("check", "Run unit tests");
    check.dependOn(&run_utf16.step);
    check.dependOn(&run_ascii.step);
    check.dependOn(&run_emit.step);
    check.dependOn(&run_chunk.step);
    check.dependOn(&run_io.step);
}
