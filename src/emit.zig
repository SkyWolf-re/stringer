//! emit.zig
//!
//! Author: skywolf
//! Date: 2025-09-27 | Last modified: 2025-10-15
//!
//! Thread-safe printers for text and JSON lines
//! - `SafePrinter` wraps any <Writer> with a mutex & pointer to a specific writer destination
//! - ASCII emits bytes as-is (escaped for text mode)
//! - UTF-16LE emitter decodes ASCII-range code units to 1-byte UTF-8
//!
//! Notes:
//! - We build each line in a temporary buffer, then lock only for the final write
//!   to minimize contention under multi-threaded scans
//! - All cap logic directly under emitters to avoid misplaced truncations
//! - Output goes through a pluggable `Sink` (ctx + writeAllFn), not std.io.Writer.
//!   This decouples emitters from OS handles and makes testing easy (ArrayList/File sink)
//!   A sink must consume the entire slice or error. It's built the line in-memory,
//!   taking the lock once and write via the sink.

const std = @import("std");
const types = @import("types");

// Opaque pointer to the concrete target (ArrayList, File, etc.) because god fucking damn it
pub const Sink = struct {
    ctx: *const anyopaque,

    // Type-erased "write all" function: must consume the full slice or error
    writeAllFn: *const fn (ctx: *const anyopaque, data: []const u8) anyerror!void,

    pub const Ctx = struct {
        list: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
    };

    pub fn writeAll(self: Sink, data: []const u8) !void {
        try self.writeAllFn(self.ctx, data);
    }

    pub fn writeByte(self: *const Sink, b: u8) !void {
        var one: [1]u8 = .{b};
        try self.writeAll(&one);
    }

    //ArrayList<u8> adapter
    pub fn sinkArrayList(ctx: *const Ctx) Sink {
        const Impl = struct {
            fn writeAll(pctx: *const anyopaque, data: []const u8) anyerror!void {
                const c: *const Ctx = @ptrCast(@alignCast(pctx));
                try c.list.appendSlice(c.alloc, data);
            }
        };
        return .{ .ctx = ctx, .writeAllFn = Impl.writeAll };
    }

    //File adapter (stdout, files); loops for short writes
    pub fn sinkFile(file: *const std.fs.File) Sink {
        const Impl = struct {
            fn writeAll(ctx: *const anyopaque, data: []const u8) anyerror!void {
                const f: *const std.fs.File = @ptrCast(@alignCast(ctx));
                var off: usize = 0;
                while (off < data.len) {
                    const n = try f.write(data[off..]);
                    off += n;
                }
            }
        };
        return .{ .ctx = file, .writeAllFn = Impl.writeAll };
    }
};

// C++ template ahh situation
pub fn SafePrinter(comptime W: type) type {
    return struct {
        lock: std.Thread.Mutex = .{},
        writer: W,
        cfg: *const types.Config,
        sink: Sink,

        pub fn init(cfg: *const types.Config, writer: W, sink: Sink) @This() {
            return .{ .writer = writer, .cfg = cfg, .sink = sink };
        }

        fn flushLine(self: *@This(), line: []const u8) !void {
            self.lock.lock();
            defer self.lock.unlock();
            try self.sink.writeAll(line);
            try self.sink.writeByte('\n');
        }

        //--------------------------------JSON ---------------------------------------------------------------

        fn jsonEscape(out: anytype, s: []const u8) !void {
            //Escape for JSON strings. data is ASCII, but handles control bytes too
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

        fn writeJsonLine(self: *@This(), offset: u64, kind: types.Kind, chars: usize, text: []const u8) !void {
            //building the line in a temp buffer (no lock), then single locked write
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

            try self.flushLine(buf.items);
        }

        fn writeTextLine(self: *@This(), offset: u64, kind: types.Kind, chars: usize, text: []const u8) !void {
            const A = std.heap.page_allocator;
            var q = std.ArrayList(u8).empty;
            defer q.deinit(A);

            // escaping minimal set for readable text mode, no cap here
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
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

            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(A);
            var w = buf.writer(A);

            const kind_s = switch (kind) {
                .ascii => "ascii   ",
                .utf16le => "utf16le ",
                .utf16be => "utf16be ",
            };

            try w.print("{x:0>16} {s} len={d} \"", .{ offset, kind_s, chars });
            try w.writeAll(q.items);
            try w.writeAll("\"");
            try w.writeByte('\n');
            try self.flushLine(buf.items);

            //self.lock.lock();
            //defer self.lock.unlock();
            //const temp_w = std.io.Writer(@TypeOf(self.writer));
            //try temp_w.print(&self.writer, "{x:0>16} {s} len={d} \"{s}\"\n", .{ offset, kind_s, chars, q.items });
        }

        //-----------------------------------------Public emit API ----------------------------------------------------

        pub fn emitAscii(self: *@This(), offset: u64, chars: usize, ascii_bytes: []const u8) !void {
            const payload = if (ascii_bytes.len > self.cfg.cap_run_bytes) ascii_bytes[0..self.cfg.cap_run_bytes] else ascii_bytes;
            if (self.cfg.json)
                try self.writeJsonLine(offset, .ascii, chars, payload)
            else
                try self.writeTextLine(offset, .ascii, chars, payload);
        }

        pub fn emitUtf16le(self: *@This(), offset: u64, chars: usize, region: []const u8) !void {
            //Decode ASCII-range UTF-16LE to 1-byte UTF-8
            var out = std.ArrayList(u8).empty;
            defer out.deinit(std.heap.page_allocator);

            const max_units = @min(chars, region.len / 2);

            var i: usize = 0;
            var emitted: usize = 0;
            while (i + 1 < region.len and emitted < max_units) : (i += 2) {
                //detector guarantees hi==0 and printable(lo)
                try out.append(std.heap.page_allocator, region[i]);
                emitted += 1;
                if (out.items.len == self.cfg.cap_run_bytes) break;
            }

            if (self.cfg.json)
                try self.writeJsonLine(offset, .utf16le, emitted, out.items)
            else
                try self.writeTextLine(offset, .utf16le, emitted, out.items);
        }
    };
}
