//! main.zig
//!
//! Author: skywolf
//! Date: 2025-09-28 | Last modified: 2025-10-15
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
    const Item = struct { on: bool, label: []const u8 };

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
    const items = [_]Item{
        .{ .on = def.enc_ascii, .label = "ascii" },
        .{ .on = def.enc_utf16le, .label = "utf16le" },
        .{ .on = def.enc_utf16be, .label = "utf16be" },
    };
    var first = true;
    for (items) |it| {
        if (!it.on) continue;
        if (!first) std.debug.print(",", .{});
        std.debug.print("{s}", .{it.label});
        first = false;
    }

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
            const v = it.next() orelse return error.InvalidArgs; //zig's pinnacle
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
fn WorkerCtx(comptime W: type) type {
    return struct {
        cfg: *const types.Config,
        pr: *emit.SafePrinter(W),
        buf: []const u8,
        tiles: []const chunk.Work,
        next: *std.atomic.Value(usize), // work-queue index
    };
}
fn workerLoop(comptime W: type, wc: *WorkerCtx(W)) void {
    while (true) {
        const i = wc.next.fetchAdd(1, .acq_rel);
        if (i >= wc.tiles.len) break;

        const t = wc.tiles[i];

        // absolute tile -> slice once; core window becomes relative
        const slice = wc.buf[t.start..t.end];
        const core_s = t.core_start - t.start;
        const core_e = t.core_end - t.start;

        if (t.enc_ascii)
            detect_ascii.scanAscii(W, wc.cfg, t.start, core_s, core_e, slice, wc.pr) catch |e| std.debug.print("worker ascii error: {s}\n", .{@errorName(e)});
        if (t.enc_utf16le)
            detect_utf16.scanUtf16le(W, wc.cfg, t.start, core_s, core_e, slice, wc.pr) catch |e| std.debug.print("worker utf16 error: {s}\n", .{@errorName(e)});
    }
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
    const stdout_file = std.fs.File.stdout();
    var buf: [64 * 1024]u8 = undefined;
    const w = stdout_file.writer(buf[0..]); // fs.File.Writer with buffer

    const Printer = emit.SafePrinter(@TypeOf(w));
    var pr = Printer.init(&cfg, w, emit.Sink.sinkFile(&stdout_file));

    //safe overlap 1 MiB default)-
    const tiles = try chunk.makeChunks(gpa, bytes.data.len, &cfg, 1 << 20);
    defer gpa.free(tiles);

    const want_threads: usize = if (cfg.threads == 0)
        (std.Thread.getCpuCount() catch 1)
    else
        cfg.threads;

    const n_workers: usize = @max(@as(usize, 1), @min(want_threads, tiles.len));

    // Work-queue
    var next_idx: std.atomic.Value(usize) = .{ .raw = 0 };
    const WC = WorkerCtx(@TypeOf(w));
    var wc: WC = .{ .cfg = &cfg, .pr = &pr, .buf = bytes.data, .tiles = tiles, .next = &next_idx };

    if (n_workers == 1) {
        //single-thread path (no spawn)
        workerLoop(@TypeOf(w), &wc);
    } else {
        const Entry = struct {
            fn run(ctx: *WC) void {
                workerLoop(@TypeOf(w), ctx);
            }
        };
        var threads = try gpa.alloc(std.Thread, n_workers);
        defer gpa.free(threads);

        var i: usize = 0;
        while (i < n_workers) : (i += 1) {
            threads[i] = try std.Thread.spawn(.{}, Entry.run, .{&wc});
        }
        for (threads) |t| t.join();
    }
}
