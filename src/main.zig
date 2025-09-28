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
const emit = @import("emit");
const chunk = @import("chunk");
const io = @import("io");
const detect_ascii = @import("detect_ascii");
const detect_utf16 = @import("detect_utf16");

//-------------------------------------CLI---------------------------------------------------------

const Parsed = struct {
    cfg: types.Config,
    path: []const u8,
};

const Opt = enum {
    // long flags
    min_len,
    enc,
    threads,
    json,
    null_only,
    cap_run_bytes,
    version,
    help,
    // short aliases
    m_min_len,
    e_enc,
    t_threads,
    j_json,
    n_null_only,
    c_cap_run_bytes,
    v_version,
    h_help,
    // meta
    positional,
    unknown,
};

const OPTS = std.StaticStringMap(Opt).initComptime(.{
    // long
    .{ "--min-len", .min_len },
    .{ "--enc", .enc },
    .{ "--threads", .threads },
    .{ "--json", .json },
    .{ "--null-only", .null_only },
    .{ "--cap-run-bytes", .cap_run_bytes },
    .{ "--version", .version },
    .{ "--help", .help },
    // short
    .{ "-m", .m_min_len },
    .{ "-e", .e_enc },
    .{ "-t", .t_threads },
    .{ "-j", .j_json },
    .{ "-n", .n_null_only },
    .{ "-c", .c_cap_run_bytes },
    .{ "-v", .v_version },
    .{ "-h", .h_help },
});

fn classify(arg: []const u8) Opt {
    if (arg.len == 0 or arg[0] != '-') return .positional;
    return OPTS.get(arg) orelse .unknown;
}

fn printHelp() void {
    const def = types.Config{};

    //building default enc list without heap alloc
    const first = true;
    const enc_fmt = struct {
        fn printList() void {
            if (def.enc_ascii) {
                std.debug.print("ascii", .{});
                first = false;
            }
            if (def.enc_utf16le) {
                std.debug.print(if (first) "utf16le" else ",utf16le", .{});
                first = false;
            }
            if (def.enc_utf16be) {
                std.debug.print(if (first) "utf16be" else ",utf16be", .{});
            }
        }
    };

    std.debug.print(
        \\stringer [options] <file|->
        \\
        \\Options:
        \\
    , .{});

    // --min-len
    std.debug.print("  --min-len N          Minimum characters per hit (default {d})\n", .{def.min_len});

    // --enc
    std.debug.print("  --enc LIST           ascii,utf16le,utf16be,all  (default: ", .{});
    enc_fmt.printList();
    std.debug.print(")\n", .{});

    // --threads / -t
    std.debug.print("  --threads N|auto     Worker threads (default: {d}; auto=#cpus)\n", .{if (def.threads == 0) 1 else def.threads});

    // --json / -j
    std.debug.print("  --json, -j           Emit JSON lines\n", .{});

    // --null-only / -n
    std.debug.print("  --null-only, -n      Require \\0 / 0x0000 terminator before emit\n", .{});

    // --cap-run-bytes
    std.debug.print("  --cap-run-bytes N    Truncate very long runs (default {d})\n", .{def.cap_run_bytes});

    // --help / --version
    std.debug.print("  --version            Print version and exit\n", .{});
    std.debug.print("  --help, -h           Show help\n\n", .{});
}

fn parseEncList(cfg: *types.Config, list: []const u8) !void {
    cfg.enc_ascii = false;
    cfg.enc_utf16le = false;
    cfg.enc_utf16be = false;

    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (std.mem.eql(u8, tok, "ascii")) {
            cfg.enc_ascii = true;
        } else if (std.mem.eql(u8, tok, "utf16le")) {
            cfg.enc_utf16le = true;
        } else if (std.mem.eql(u8, tok, "utf16be")) {
            cfg.enc_utf16be = true;
        } else if (std.mem.eql(u8, tok, "all")) {
            cfg.enc_ascii = true;
            cfg.enc_utf16le = true;
            cfg.enc_utf16be = true;
        } else return error.InvalidArgs;
    }
}

fn parseArgs(alloc: std.mem.Allocator) !Parsed {
    _ = alloc; //reserved for future use

    var cfg = types.Config{};
    const path_opt: ?[]const u8 = null;

    var it = std.process.args();
    _ = it.next(); // skip argv0

    while (it.next()) |arg| switch (classify(arg)) {
        .min_len, .m_min_len => {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.min_len = try std.fmt.parseUnsigned(usize, v, 10);
        },
        .enc, .e_enc => {
            const v = it.next() orelse return error.InvalidArgs;
            try parseEncList(&cfg, v);
        },
        .threads, .t_threads => {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.threads = if (std.mem.eql(u8, v, "auto")) 0 else try std.fmt.parseUnsigned(usize, v, 10);
        },
        .json, .j_json => cfg.json = true,
        .null_only, .n_null_only => cfg.null_only = true,
        .cap_run_bytes, .c_cap_run_bytes => {
            const v = it.next() orelse return error.InvalidArgs;
            cfg.cap_run_bytes = try std.fmt.parseUnsigned(usize, v, 10);
        },
        .version, .v_version => {
            std.debug.print("stringer 0.1.0\n", .{});
            std.process.exit(0);
        },
        .help, .h_help => {
            printHelp();
            std.process.exit(0);
        },
        .positional => {},
        .unknown => return error.InvalidArgs,
    };

    const path = path_opt orelse return error.InvalidArgs;
    try cfg.validate();
    return .{ .cfg = cfg, .path = path };
}

//-------------------------------------Worker orchestration---------------------------------------------------------

const RunCtx = struct {
    cfg: *const types.Config,
    pr: *emit.SafePrinter,
    w: *const chunk.Work,
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
    var printer = emit.SafePrinter.init(&cfg, std.io.getStdOut().writer().any());

    //Plan chunks with overlap
    const works = try chunk.makeChunks(gpa, bytes.data, &cfg);
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
