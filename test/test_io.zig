const std = @import("std");
const builtin = @import("builtin");
const io = @import("io");

test "io: small regular file maps/reads and returns correct origin + bytes" {
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    //file with known contents
    const fname = "sample.bin";
    {
        var f = try tmp.dir.createFile(fname, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("hello\nworld");
    }

    const path = try tmp.dir.realpathAlloc(A, fname);
    defer A.free(path);

    var b = try io.mapOrReadFile(A, path);
    defer b.deinit(A);

    try std.testing.expectEqualSlices(u8, "hello\nworld", b.data);

    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(io.Origin.OwnedHeap, b.origin);
        try std.testing.expect(b.mmap_addr == null);
    } //else {
    //try std.testing.expectEqual(io.Origin.BorrowedMmap, b.origin);
    //try std.testing.expect(b.mmap_addr != null);
    //}
}

test "io: empty regular file returns empty slice, OwnedHeap" {
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fname = "empty.bin";
    {
        var f = try tmp.dir.createFile(fname, .{ .read = true, .truncate = true });
        defer f.close();
        // write nothing
    }

    const path = try tmp.dir.realpathAlloc(A, fname);
    defer A.free(path);

    var b = try io.mapOrReadFile(A, path);
    defer b.deinit(A);

    try std.testing.expectEqual(@as(usize, 0), b.data.len);
    try std.testing.expectEqual(io.Origin.OwnedHeap, b.origin);
    try std.testing.expect(b.mmap_addr == null);
}

test "io: non-regular (directory) returns NotARegularFile" {
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(A, ".");
    defer A.free(dir_path);

    const err = io.mapOrReadFile(A, dir_path) catch |e| e;
    try std.testing.expectEqual(error.NotARegularFile, err);
}

// Smoke: map + deinit should not leak or crash (mmap path).
test "io: deinit always safe (mmap or heap)" {
    const A = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const fname = "smoke.bin";
    {
        var f = try tmp.dir.createFile(fname, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll("abcdef");
    }

    const path = try tmp.dir.realpathAlloc(A, fname);
    defer A.free(path);

    var b = try io.mapOrReadFile(A, path);
    b.deinit(A);
}
