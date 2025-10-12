//! io.zig
//!
//! Author: skywolf
//! Date: 2025-09-28 | Last modified: 2025-10-12
//!
//! Map or read input into a contiguous byte slice.
//! - `-` reads stdin fully (owned heap buffer)
//! - For facility, all is in heap buffer -> good for small-medium files, but mmap
//!   will be added later for larger ones
//! LATER ADDS:
//! - POSIX files are memory-mapped (borrowed; deinit() will munmap)
//! - Windows falls back to read-all (owned heap buffer) for MVP
//!
//! Notes:
//! - Uses `Bytes.deinit(alloc)` to release resources regardless of origin
//! - Zero-length files return an empty slice (no mmap)

const std = @import("std");
const builtin = @import("builtin");

pub const Origin = enum {
    OwnedHeap, //malloc'd / allocator-owned
    BorrowedMmap, //POSIX mmap
};

pub const Bytes = struct {
    data: []const u8,
    origin: Origin,
    ///non-null only when origin == BorrowedMmap (page-aligned addr returned by mmap)
    mmap_addr: ?[*]const u8 = null,

    /// Release memory / unmap if needed.
    pub fn deinit(self: *Bytes, alloc: std.mem.Allocator) void {
        switch (self.origin) {
            .OwnedHeap => {
                if (self.data.len != 0) {
                    alloc.free(@constCast(self.data));
                }
            },
            .BorrowedMmap => {
                //  if (self.data.len != 0) {
                //      if (self.mmap_addr) |addr| {
                //munmap needs the original page-aligned base pointer and the mapped length
                //         const region: []align(std.mem.page_size) const u8 = addr[0..self.data.len];
                //         std.posix.munmap(region); // no second length arg on 0.15.x
                //     }
                //  }
            },
        }
        //Resetting to prevent accidental reuse
        self.* = .{ .data = &[_]u8{}, .origin = .OwnedHeap, .mmap_addr = null };
    }
};

pub fn mapOrReadFile(alloc: std.mem.Allocator, path: []const u8) !Bytes {
    // STDIN: read-all into owned heap memory
    if (std.mem.eql(u8, path, "-")) {
        var file = std.fs.File.stdin();
        var rbuf: [64 * 1024]u8 = undefined;
        var reader = file.reader(rbuf[0..]);

        var out = std.ArrayList(u8).empty;
        defer out.deinit(alloc);

        var scratch: [64 * 1024]u8 = undefined;
        while (true) {
            const n = try reader.read(&scratch);
            if (n == 0) break;
            try out.appendSlice(alloc, scratch[0..n]);
        }

        return .{
            .data = try out.toOwnedSlice(alloc),
            .origin = .OwnedHeap,
            .mmap_addr = null,
        };
    }

    // Open file and stat
    var file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    const st = try file.stat();
    if (st.kind != .file) return error.NotARegularFile;

    // Empty file
    if (st.size == 0) {
        return .{ .data = &[_]u8{}, .origin = .OwnedHeap, .mmap_addr = null };
    }

    const len = std.math.cast(usize, st.size) orelse return error.FileTooLarge;

    // Read-all path (works everywhere)
    var buf = try alloc.alloc(u8, len);
    const n = try file.readAll(buf);
    return .{ .data = buf[0..n], .origin = .OwnedHeap, .mmap_addr = null };

    //if (builtin.os.tag != .windows) {
    //POSIX mmap (read-only, private)
    //  var prot = std.posix.PROT{}; // all false by default
    // prot.READ = true;

    //  var flags = std.posix.MAP{};
    //  flags.PRIVATE = true;

    // mmap
    //  const p = try std.posix.mmap(
    //      null,
    //      st.size,
    //      prot,
    //      flags,
    //      file.handle,
    //      0,
    //  );
    //keeping the page-aligned base for munmap
    // const addr: [*]const u8 = @ptrCast(p);
    //  const slice = addr[0..len];

    // return .{
    //      .data = slice,
    //     .origin = .BorrowedMmap,
    //      .mmap_addr = addr,
    //  };
    // } else {
    //Windows MVP: read-all into owned buffer (add file mapping later)
    //    var buf = try alloc.alloc(u8, len);
    //   const readn = try file.readAll(buf);
    //   return .{ .data = buf[0..readn], .origin = .OwnedHeap, .mmap_addr = null };
    // }
}
