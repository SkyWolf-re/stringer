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

    mod_chunk.addImport("types", mod_types);
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
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run stringer").dependOn(&run_cmd.step);

    const test_mod_utf16 = b.createModule(.{
        .root_source_file = .{ .cwd_relative = "test/test_detect_utf16.zig" },
        .target = target,
        .optimize = optimize,
    });
    test_mod_utf16.addImport("types", mod_types);
    test_mod_utf16.addImport("emit", mod_emit);
    test_mod_utf16.addImport("detect_ascii", mod_detect_ascii);
    test_mod_utf16.addImport("detect_utf16", mod_detect_utf16);
    test_mod_utf16.addImport("chunk", mod_chunk);
    test_mod_utf16.addImport("io", mod_io);

    const t_utf16 = b.addTest(.{ .root_module = test_mod_utf16 });
    const run_tests = b.addRunArtifact(t_utf16);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
