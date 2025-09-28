//! emit.zig
//!
//! Author: skywolf
//! Date: 2025-09-27
//!
//! Thread-safe printers for text and JSON lines
//! - `SafePrinter` wraps an `AnyWriter` with a mutex
//! - ASCII emits bytes as-is (escaped for text mode)
//! - UTF-16LE emitter decodes ASCII-range code units to 1-byte UTF-8
//!
//! Notes:
//! - We build each line in a temporary buffer, then lock only for the final write
//!   to minimize contention under multi-threaded scans

const std = @import("std");
const types = @import("types");

pub const SafePrinter = struct {
    lock: std.Thread.Mutex = .{},
    writer: std.io.AnyWriter,
    cfg: *const types.Config,

    pub fn init(cfg: *const types.Config, writer: std.io.AnyWriter) SafePrinter {
        return .{ .writer = writer, .cfg = cfg };
    }

    //--------------------------------JSON ---------------------------------------------------------------

    fn jsonEscape(out: anytype, s: []const u8) !void {
        // Escape for JSON strings. Our data is ASCII, but handle control bytes too.
        for (s) |b| switch (b) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => {
                if (b < 0x20) { // other control chars -> \u00XX
                    try out.print("\\u{0:0>4}", .{@as(u16, b)});
                } else {
                    try out.writeByte(b);
                }
            },
        };
    }

    fn writeJsonLine(self: *SafePrinter, offset: usize, kind: types.Kind, chars: usize, text: []const u8) !void {
        // Build the line in a temp buffer (no lock), then single locked write.
        const A = std.heap.page_allocator;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(A);
        var w = buf.writer(A);

        const kind_s = switch (kind) {
            .ascii => "ascii",
            .utf16le => "utf16le",
            .utf16be => "utf16be",
        };

        try w.writeByte('{');
        try w.writeAll("\"offset\":");
        try w.print("{}", .{offset});
        try w.writeAll(",\"kind\":\"");
        try w.writeAll(kind_s);
        try w.writeAll("\",\"len\":");
        try w.print("{}", .{chars});
        try w.writeAll(",\"text\":\"");
        try jsonEscape(w, text);
        try w.writeAll("\"}");

        self.lock.lock();
        defer self.lock.unlock();
        try self.writer.writeAll(buf.items);
        try self.writer.writeByte('\n');
    }

    fn writeTextLine(self: *SafePrinter, offset: usize, kind: types.Kind, chars: usize, text: []const u8) !void {
        const A = std.heap.page_allocator;
        var q = std.ArrayList(u8).empty;
        defer q.deinit(A);

        // escape minimal set for readable text mode and cap length
        var i: usize = 0;
        while (i < text.len and q.items.len < self.cfg.cap_run_bytes) : (i += 1) {
            const b = text[i];
            switch (b) {
                '\n' => try q.appendSlice(A, "\\n"),
                '\r' => try q.appendSlice(A, "\\r"),
                '\t' => try q.appendSlice(A, "\\t"),
                '\\', '"' => {
                    try q.append(A, '\\');
                    try q.append(A, b);
                },
                else => try q.append(A, b),
            }
        }

        const kind_s = switch (kind) {
            .ascii => "ascii   ",
            .utf16le => "utf16le ",
            .utf16be => "utf16be ",
        };

        self.lock.lock();
        defer self.lock.unlock();
        try self.writer.print("{x:0>8}  {s} len={d}  \"{s}\"\n", .{ offset, kind_s, chars, q.items });
    }

    //-----------------------------------------Public emit API ----------------------------------------------------

    pub fn emitAscii(self: *SafePrinter, offset: usize, chars: usize, ascii_bytes: []const u8) !void {
        if (self.cfg.json)
            try self.writeJsonLine(offset, .ascii, chars, ascii_bytes)
        else
            try self.writeTextLine(offset, .ascii, chars, ascii_bytes);
    }

    pub fn emitUtf16le(self: *SafePrinter, offset: usize, chars: usize, region: []const u8) !void {
        //Decode ASCII-range UTF-16LE to 1-byte UTF-8
        var out = std.ArrayList(u8).empty;
        defer out.deinit(std.heap.page_allocator);

        var i: usize = 0;
        var emitted: usize = 0;
        while (i + 1 < region.len and emitted < chars and out.items.len < self.cfg.cap_run_bytes) : (i += 2) {
            // detector guarantees hi==0 and printable(lo)
            try out.append(std.heap.page_allocator, region[i]);
            emitted += 1;
        }

        if (self.cfg.json)
            try self.writeJsonLine(offset, .utf16le, emitted, out.items)
        else
            try self.writeTextLine(offset, .utf16le, emitted, out.items);
    }
};
