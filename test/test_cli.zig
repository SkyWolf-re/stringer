const std = @import("std");

//Optional: embed a C source sample
const sample_c_src: []const u8 = @embedFile("samples/a.out");

fn writeFile(p: []const u8, bytes: []const u8) !void {
    var f = try std.fs.cwd().createFile(p, .{ .truncate = true, .read = true });
    defer f.close();
    _ = try f.write(bytes);
}

fn runStringer(
    alloc: std.mem.Allocator,
    exe_path: []const u8,
    args: []const []const u8,
) !struct { stdout: []u8, stderr: []u8, code: u8 } {
    // argv = [exe, args...]
    //var argv = try alloc.alloc([]const u8, 1 + args.len);
    //defer alloc.free(argv);

    //const exe_abs = try std.fs.cwd().realpathAlloc(alloc, exe_path);
    //defer alloc.free(exe_abs);
    //argv[0] = exe_abs;

    //std.mem.copyForwards([]const u8, argv[1..], args);
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(alloc);
    try argv.append(alloc, exe_path);
    try argv.appendSlice(alloc, args);

    for (argv.items, 0..) |s, i| {
        std.debug.print("parent argv[{d}] = '{s}'\n", .{ i, s });
    }

    var child = std.process.Child.init(argv.items, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // If your tool needs to run inside tmp dir so relative inputs resolve:
    // child.cwd = tmp_dir_path;

    try child.spawn();

    const out = try child.stdout.?.readToEndAlloc(alloc, 10 * 1024 * 1024);
    errdefer alloc.free(out);
    const err = try child.stderr.?.readToEndAlloc(alloc, 64 * 1024);
    errdefer alloc.free(err);

    const term = try child.wait();
    const code: u8 = switch (term) {
        .Exited => |s| @intCast(s),
        else => 255,
    };

    return .{ .stdout = out, .stderr = err, .code = code };
}

//tiny ahh .bin that contains true NULs to test --null-only
fn makeHelloBin(alloc: std.mem.Allocator) ![]u8 {
    var a = std.ArrayList(u8).empty;
    errdefer a.deinit(alloc);

    try a.appendSlice(alloc, "ONE");
    try a.append(alloc, 0);
    try a.appendSlice(alloc, "TWO");
    try a.append(alloc, 0);
    try a.appendSlice(alloc, "THREE");
    try a.append(alloc, 0);

    return try a.toOwnedSlice(alloc);
}

test "CLI: scan a real C source and a NUL-terminated binary" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Absolute path to the temp dir (for passing to the CLI)
    const base = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base);

    // Read the repo file: test/samples/sample.c
    const src_rel = try std.fs.path.join(gpa, &.{ "test", "samples", "a.out" });
    defer gpa.free(src_rel);

    const src_bytes = try std.fs.cwd().readFileAlloc(gpa, src_rel, 1 << 20);
    defer gpa.free(src_bytes);

    // Materialize it inside the temp dir
    try tmp.dir.writeFile(.{ .sub_path = "a.out", .data = src_bytes });

    // Build absolute path to the file in tmp (used by your CLI)
    const src_path = try std.fs.path.join(gpa, &.{ base, "a.out" });
    defer gpa.free(src_path);

    // Now run your tool with src_path...
    const exe_path = try std.fs.realpathAlloc(gpa, "zig-out/bin/stringer");
    defer gpa.free(exe_path);

    std.debug.print("exe_path = {s}\n", .{exe_path});
    const res = try runStringer(gpa, exe_path, &.{ "--json", "--min-len", "5", "--enc", "ascii", src_path });

    if (res.code != 0) {
        std.debug.print("stringer exited {d}\nstderr:\n{s}\nstdout:\n{s}\n", .{ res.code, res.stderr, res.stdout });
    }
    defer {
        gpa.free(res.stdout);
        gpa.free(res.stderr);
    }
    try std.testing.expectEqual(@as(u8, 0), res.code);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "\"text\":\"include\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res.stdout, "\"kind\":\"ascii\"") != null);

    //--------------------Real NUL-terminated strings in hello.bin--------------------------------

    const bin_bytes = try makeHelloBin(gpa);
    defer gpa.free(bin_bytes);

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();

    try tmp2.dir.writeFile(.{ .sub_path = "hello.bin", .data = bin_bytes });

    const base2 = try tmp2.dir.realpathAlloc(gpa, ".");
    defer gpa.free(base2);

    const bin_path = try std.fs.path.join(gpa, &.{ base2, "hello.bin" });
    defer gpa.free(bin_path);

    const res1 = try runStringer(
        gpa,
        exe_path,
        &.{ "--json", "--min-len", "3", "--enc", "ascii", "--null-only", bin_path },
    );
    defer {
        gpa.free(res1.stdout);
        gpa.free(res1.stderr);
    }

    try std.testing.expectEqual(@as(u8, 0), res1.code);
    try std.testing.expect(std.mem.indexOf(u8, res1.stdout, "\"text\":\"ONE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res1.stdout, "\"text\":\"TWO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, res1.stdout, "\"text\":\"THREE\"") != null);

    // no duplicates
    const needle = "\"text\":\"ONE\"";
    const one_first = std.mem.indexOf(u8, res1.stdout, needle);
    const start_idx = (one_first orelse 0) + 1;
    try std.testing.expect(std.mem.indexOfPos(u8, res1.stdout, start_idx, needle) == null);
}
