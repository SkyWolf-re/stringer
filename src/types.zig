//! types.zig
//!
//! Author: skywolf
//! Date: 2025-09-28 | Last modified: 2025-10-23
//!
//! Canonical shared types for the string scanner
//! - Defines the configuration struct (`Config`) with safe defaults and a
//!   `validate()` routine to catch bad CLI inputs early
//! - Defines the `Kind` enum (detector type) and the `Hit` metadata struct
//!   used by emitters/printers
//! - No globals; all data passed explicitly to keep threading safe
//! - Lazily create an arena in Config to own `find` patterns: duplicate the argv bytes into the arena
//!   `addFindPattern` and store the slices in cfg.find (OR-semantics)
//!
//! Notes:
//! - `offset` in `Hit` is a *file byte offset*, not RVA/VA
//! - `chars` counts codepoints: ASCII counts bytes, UTF-16 counts 16-bit units

const std = @import("std");

pub const Kind = enum { ascii, utf16le, utf16be };

pub const Config = struct {
    min_len: usize = 2,
    enc_ascii: bool = true,
    enc_utf16le: bool = true,
    enc_utf16be: bool = false,
    threads: usize = 1, //0 = auto
    json: bool = false,
    null_only: bool = false,
    cap_run_bytes: usize = 4096,
    find: [][]const u8 = &.{},
    _arena: ?*std.heap.ArenaAllocator = null,

    pub fn validate(self: *const Config) !void {
        if (self.min_len < 2) return error.MinLenTooSmall;
        if (!self.enc_ascii and !self.enc_utf16le and !self.enc_utf16be)
            return error.NoEncodingsSelected;
        if (self.cap_run_bytes == 0) return error.InvalidCap;
    }

    fn ensureArena(self: *Config, parent: std.mem.Allocator) !*std.heap.ArenaAllocator {
        if (self._arena) |a| return a;
        const a = try parent.create(std.heap.ArenaAllocator);
        a.* = std.heap.ArenaAllocator.init(parent);
        self._arena = a;
        return a;
    }

    pub fn addFindPattern(self: *Config, parent: std.mem.Allocator, pat: []const u8) !void {
        const arena = try self.ensureArena(parent);
        const aa = arena.allocator();

        const copy = try aa.dupe(u8, pat);
        var list = std.ArrayList([]const u8).fromOwnedSlice(self.find);
        try list.append(aa, copy);
        self.find = list.items;
    }

    pub fn deinit(self: *Config, parent: std.mem.Allocator) void {
        if (self._arena) |a| {
            a.deinit();
            parent.destroy(a);
            self._arena = null;
        }
    }
};

pub const Hit = struct {
    offset: u64, //absolute file byte offset (NOT RVA)
    kind: Kind,
    chars: usize, //ASCII: bytes; UTF-16: 16-bit code units
    //text is printed by the emitter directly from a slice, so no need to store it here
};
