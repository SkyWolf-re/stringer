//! chunk.zig
//!
//! Author: skywolf
//! Date: 2025-09-28 | Last modification: 2025-09-30
//!
//! Slice a file buffer into work chunks with safe boundary overlap.
//! - Ensures each chunk has a non-overlap "core" window where string-starts
//!   are allowed to be emitted (prevents duplicates across workers)
//! - Overlap is the max needed by enabled detectors, including the terminator
//!   when `--null-only` is set:
//!     ASCII  : (min_len - 1) + (null_only ? 1 : 0)
//!     UTF-16 : 2*(min_len - 1) + (null_only ? 2 : 0)
//! - Tile size is hint-based (e.g. 1 MiB) and clamped so cores are never empty
//! - If tile_size_hint == 0, chooseTileSize() auto-picks a tile size.
//!
//! Notes:
//! - For very small inputs (or zero length), we fall back to a single chunk
//! - Left/right edges are clamped (no usize under/overflow)
//! - Returns only initialized tiles; no uninitialized entries are exposed
//! - When `tile_size_hint = 0`, tile size is auto-scaled based on CPU concurrency: target ~= file_len/(workers*4),
//!   where workers = cfg.threads or detected CPU count. The value is clamped/aligned to [64 KiB..2 MiB] and
//!   forced to be ≥ 8xoverlap, ensuring cores remain much larger than the detector overlap

const std = @import("std");
const types = @import("types");

pub const Work = struct {
    ///Absolute byte indices into the full file buffer
    start: usize, //inclusive, with left overlap
    end: usize, //exclusive, with right overlap

    ///Absolute core window (no overlap)
    core_start: usize,
    core_end: usize,

    enc_ascii: bool,
    enc_utf16le: bool,
};

fn computeOverlap(cfg: *const types.Config) usize {
    var ov_ascii: usize = 0;
    if (cfg.enc_ascii) {
        ov_ascii = (cfg.min_len - @as(usize, 1)) + (if (cfg.null_only) @as(usize, 1) else @as(usize, 0));
    }

    var ov_u16: usize = 0;
    if (cfg.enc_utf16le or cfg.enc_utf16be) {
        ov_u16 = (@as(usize, 2) * (cfg.min_len - @as(usize, 1))) + (if (cfg.null_only) @as(usize, 2) else @as(usize, 0));
    }

    return if (ov_ascii > ov_u16) ov_ascii else ov_u16;
}

// Chooses a good tile size for linear scans. Auto-scale is fancy
pub fn chooseTileSize(file_len: usize, workers_hint: usize, ov: usize) usize {
    const floor32k: usize = 32 * 1024;
    const min64k: usize = 64 * 1024;
    const max2m: usize = 2 * 1024 * 1024;

    const workers = if (workers_hint == 0) 1 else workers_hint;

    var target = file_len / (workers * 4 + 1);
    if (target < min64k) target = min64k;
    if (target > max2m) target = max2m;

    const need = ov * 8;
    if (target < need) target = need;

    if (target < floor32k) target = floor32k;
    return std.mem.alignForward(usize, target, 64 * 1024);
}

//fixed-size tiles that cover the file with safe overlap cuz chunk math was't mathing
//Returns owned slice of Work now, no uninitialized entries
pub fn makeChunks(
    alloc: std.mem.Allocator,
    file_len: usize,
    cfg: *const types.Config,
    tile_size_hint: usize, // 0 for auto
) ![]Work {
    var list = std.ArrayList(Work).empty;
    errdefer list.deinit(alloc);

    if (file_len == 0) {
        //single empty tile (simplifies callers; detectors will no-op)
        try list.append(alloc, .{
            .start = 0,
            .end = 0,
            .core_start = 0,
            .core_end = 0,
            .enc_ascii = cfg.enc_ascii,
            .enc_utf16le = cfg.enc_utf16le,
        });
        return try list.toOwnedSlice(alloc);
    }

    const ov = computeOverlap(cfg);
    const min_tile: usize = 32 * 1024; //floor for tiny files
    var tile: usize = tile_size_hint;
    if (tile == 0) {
        const th = if (cfg.threads == 0)
            (std.Thread.getCpuCount() catch 1)
        else
            cfg.threads;
        tile = chooseTileSize(file_len, th, ov);
    }
    if (tile < min_tile) tile = min_tile;

    var pos: usize = 0;
    while (pos < file_len) {
        const core_s = pos;
        const core_e = @min(file_len, pos + tile);

        //no under/overflow possible now
        const s = core_s - @min(core_s, ov);
        const right_room = file_len - core_e; //core_e ≤ file_len
        const e = core_e + @min(ov, right_room);

        try list.append(alloc, .{
            .start = s,
            .end = e,
            .core_start = core_s,
            .core_end = core_e,
            .enc_ascii = cfg.enc_ascii,
            .enc_utf16le = cfg.enc_utf16le,
        });

        pos = core_e;
    }

    return try list.toOwnedSlice(alloc);
}
