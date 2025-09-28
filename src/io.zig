//! io.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! Map or read input into a contiguous byte slice.
//! - `-` reads stdin fully (owned heap buffer)
//! - POSIX files are memory-mapped (borrowed; deinit() will munmap)
//! - Windows falls back to read-all (owned heap buffer) for MVP
//!
//! Notes:
//! - Uses `Bytes.deinit(alloc)` to release resources regardless of origin
//! - Zero-length files return an empty slice (no mmap)

const std = @import("std");

pub const Origin = enum {
    OwnedHeap, //malloc'd / allocator-owned
    BorrowedMmap, //POSIX mmap
};

pub const Bytes = struct {
    data: []const u8,
    origin: Origin,
    ///non-null only when origin == BorrowedMmap (page-aligned addr returned by mmap)
    mmap_addr: ?[*]align(std.mem.page_size) const u8 = null,

    /// Release memory / unmap if needed.
    pub fn deinit(self: *Bytes, alloc: std.mem.Allocator) void {
        switch (self.origin) {
            .OwnedHeap => {
                if (self.data.len != 0) {
                    alloc.free(@constCast(self.data));
                }
            },
            .BorrowedMmap => {
                if (self.data.len != 0) {
                    if (self.mmap_addr) |addr| {
                        //munmap needs the original page-aligned base pointer and the mapped length
                        _ = std.posix.munmap(addr, self.data.len);
                    }
                }
            },
        }
        //Resetting to prevent accidental reuse
        self.* = .{ .data = &[_]u8{}, .origin = .OwnedHeap, .mmap_addr = null };
    }
};

pub fn mapOrReadFile(alloc: std.mem.Allocator, path: []const u8) !Bytes {
    // STDIN: read-all into owned heap memory
    if (std.mem.eql(u8, path, "-")) {
        var in = std.io.getStdIn().reader();
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(alloc);
        try in.readAllArrayList(alloc, &buf, 1 << 20); //grows as needed
        return .{ .data = try buf.toOwnedSlice(), .origin = .OwnedHeap, .mmap_addr = null };
    }

    //Open and stat
    var file = try std.fs.cwd().openFile(path, .{ .read = true });
    defer file.close();
    const st = try file.stat();

    //Rejecting non-regular files (symlinks are resolved by openFile)
    if (st.kind != .file) return error.NotARegularFile;

    //Empty file: return empty slice
    if (st.size == 0) {
        return .{ .data = &[_]u8{}, .origin = .OwnedHeap, .mmap_addr = null };
    }

    //guard cast from u64 -> usize
    const len = std.math.cast(usize, st.size) orelse return error.FileTooLarge;

    if (std.builtin.os.tag != .windows) {
        //POSIX mmap (read-only, private)
        const p = try std.posix.mmap(
            null,
            st.size,
            std.posix.PROT.READ,
            std.posix.MAP.PRIVATE,
            file.handle,
            0,
        );
        //keeping the page-aligned base for munmap
        const addr: [*]align(std.mem.page_size) const u8 = @ptrCast(p);
        const slice = addr[0..len];

        return .{
            .data = slice,
            .origin = .BorrowedMmap,
            .mmap_addr = addr,
        };
    } else {
        //Windows MVP: read-all into owned buffer (add file mapping later)
        var buf = try alloc.alloc(u8, len);
        const readn = try file.readAll(buf);
        return .{ .data = buf[0..readn], .origin = .OwnedHeap, .mmap_addr = null };
    }
}
