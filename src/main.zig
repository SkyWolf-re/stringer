//! main.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! Orchestrates the string scanner CLI
//! - Parses flags into `Config`, validates inputs
//! - Plans chunks with overlap and spawns workers
//! - Runs ASCII and UTF-16LE detectors per chunk
//! - Emits text or JSON lines via a thread-safe printer
//!
//! Notes:
//! - Offsets are absolute *file byte* offsets (not RVA/VA)
//! - De-dup is handled by emitting only when a hit's start lies in a chunk's
//!   non-overlap "core" window

const std = @import("std");
const types = @import("types");
const emm = @import("emit");
const ch = @import("chunk");
const io = @import("io");
const detect_ascii = @import("detect_ascii");
const detect_utf16 = @import("detect_utf16");

//-------------------------------------CLI---------------------------------------------------------

const Parsed = struct {
    cfg: types.Config,
    path: []const u8,
};

fn printHelp() void {
    std.debug.print(
        \\stringer [options] <file|->
        \\Options:
        \\  --min-len N         Minimum characters per hit (default 5)
        \\  --enc LIST          ascii,utf16le,utf16be,all  (default: ascii,utf16le)
        \\  --threads N|auto    Worker threads (default: 1; auto=#cpus)
        \\  --json              Emit JSON lines
        \\  --null-only         Require \\0 / 0x0000 terminator
        \\  --cap-run-bytes N   Truncate very long runs (default 4096)
        \\  --version           Print version and exit
        \\  -h, --help          Show help
        \\
    , .{});
}

fn parseArgs(alloc: std.mem.Allocator) !Parsed {
    _ = alloc; // (kept for symmetry; not needed right now)

    var cfg = types.Config{};
    var path_opt: ?[]const u8 = null;

    var it = std.process.args();
    _ = it.next(); // skip argv0

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--min-len")) {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.min_len = try std.fmt.parseUnsigned(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--enc")) {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.enc_ascii = false;
            cfg.enc_utf16le = false;
            cfg.enc_utf16be = false;
            var parts = std.mem.splitScalar(u8, v, ',');
            while (parts.next()) |tok| {
                if (std.mem.eql(u8, tok, "ascii")) cfg.enc_ascii = true else if (std.mem.eql(u8, tok, "utf16le")) cfg.enc_utf16le = true else if (std.mem.eql(u8, tok, "utf16be")) cfg.enc_utf16be = true else if (std.mem.eql(u8, tok, "all")) {
                    cfg.enc_ascii = true;
                    cfg.enc_utf16le = true;
                    cfg.enc_utf16be = true;
                } else return error.InvalidArgs;
            }
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const v = it.next() orelse return error.InvalidArgs;
            if (std.mem.eql(u8, v, "auto")) cfg.threads = 0 else cfg.threads = try std.fmt.parseUnsigned(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            cfg.json = true;
        } else if (std.mem.eql(u8, arg, "--null-only")) {
            cfg.null_only = true;
        } else if (std.mem.eql(u8, arg, "--cap-run-bytes")) {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.cap_run_bytes = try std.fmt.parseUnsigned(usize, v, 10);
        } else if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("stringer 0.1.0\n", .{});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printHelp();
            std.process.exit(0);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidArgs;
        } else {
            // positional: path
            if (path_opt != null) return error.InvalidArgs; // only one file
            path_opt = arg;
        }
    }

    if (path_opt == null) return error.InvalidArgs;

    try cfg.validate();
    return .{ .cfg = cfg, .path = path_opt.? };
}

//-------------------------------------Worker orchestration---------------------------------------------------------

const RunCtx = struct {
    cfg: *const types.Config,
    pr: *emm.SafePrinter,
    w: *const ch.Work,
};

fn runChunk(ctx: *RunCtx) !void {
    if (ctx.w.enc_ascii)
        try detect_ascii.scanAscii(ctx.cfg, ctx.w.base_offset, ctx.w.core_start, ctx.w.core_end, ctx.w.buf, ctx.pr);
    if (ctx.w.enc_utf16le)
        try detect_utf16.scanUtf16le(ctx.cfg, ctx.w.base_offset, ctx.w.core_start, ctx.w.core_end, ctx.w.buf, ctx.pr);
}

//Thread entry
fn runChunkThread(ctx: *RunCtx) void {
    //print and exit non-zero on failure
    runChunk(ctx) catch |e| {
        std.debug.print("worker error: {s}\n", .{@errorName(e)});
    };
}

//--------------------------------Main--------------------------------------------

pub fn main() !void {
    var gpa = std.heap.page_allocator;

    const parsed = parseArgs(gpa) catch {
        std.debug.print("Invalid args.\n\n", .{});
        printHelp();
        std.process.exit(2);
    };
    var cfg = parsed.cfg;
    const path = parsed.path;
    const bytes = try io.mapOrReadFile(gpa, path);
    defer {
        var b = bytes;
        b.deinit(gpa); // frees or munmaps as needed
    }

    //prepare printer
    var printer = emm.SafePrinter.init(&cfg, std.io.getStdOut().writer().any());

    //Plan chunks with overlap
    const works = try ch.makeChunks(gpa, bytes.data, &cfg);
    defer gpa.free(works);

    //Spawn threads
    var contexts = try gpa.alloc(RunCtx, works.len);
    defer gpa.free(contexts);

    var threads = try gpa.alloc(std.Thread, works.len);
    defer gpa.free(threads);

    for (works, 0..) |*w, i| {
        contexts[i] = .{ .cfg = &cfg, .pr = &printer, .w = w };
        threads[i] = try std.Thread.spawn(.{}, runChunkThread, .{&contexts[i]});
    }

    for (threads) |t| t.join();
}
