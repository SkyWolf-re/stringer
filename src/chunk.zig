//! chunk.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! Slice a file buffer into work chunks with boundary overlap.
//! - Ensures each chunk has a non-overlap "core" window where string-starts
//!   are allowed to be emitted (prevents duplicates across workers)
//! - Overlap is the max needed by enabled detectors:
//!     ASCII  -> (min_len - 1) bytes
//!     UTF-16 -> 2 * (min_len - 1) bytes
//! - Clamps thread count so chunk size is never zero
//!
//! Notes:
//! - For very small inputs (or zero length), we fall back to a single chunk

const std = @import("std");
const types = @import("types");

pub const Work = struct {
    buf: []const u8, //slice this worker scans (includes overlap)
    base_offset: usize, //absolute file offset of buf[0]
    core_start: usize, //start index inside buf where emits are allowed
    core_end: usize, //end index (exclusive) of the core window
    enc_ascii: bool,
    enc_utf16le: bool,
    enc_utf16be: bool,
};

pub fn makeChunks(alloc: std.mem.Allocator, file_buf: []const u8, cfg: *const types.Config) ![]Work {
    const len = file_buf.len;

    // Zero-length or trivially small -> single chunk
    if (len == 0 or cfg.threads == 1 or len < cfg.min_len * 8) {
        var one = try alloc.alloc(Work, 1);
        one[0] = .{
            .buf = file_buf,
            .base_offset = 0,
            .core_start = 0,
            .core_end = file_buf.len,
            .enc_ascii = cfg.enc_ascii,
            .enc_utf16le = cfg.enc_utf16le,
            .enc_utf16be = cfg.enc_utf16be,
        };
        return one;
    }

    const requested = if (cfg.threads == 0) (std.Thread.getCpuCount() catch 1) else cfg.threads;
    // Clamp to avoid zero-sized chunks (at most one chunk per byte if needed)
    const T: usize = if (len == 0) 1 else @min(requested, len);

    // Compute overlap (max of enabled detectors)
    const ascii_ov: usize = if (cfg.enc_ascii) (cfg.min_len - 1) else 0;
    const u16_ov_le: usize = if (cfg.enc_utf16le) (2 * (cfg.min_len - 1)) else 0;
    const u16_ov_be: usize = if (cfg.enc_utf16be) (2 * (cfg.min_len - 1)) else 0;
    const ov = @max(ascii_ov, @max(u16_ov_le, u16_ov_be));

    //Evenly sized chunks (floor division). Last chunk takes the remainder
    const chunk_size = len / T;

    var works = try alloc.alloc(Work, T);
    var start: usize = 0;

    var i: usize = 0;
    while (i < T) : (i += 1) {
        const end = if (i == T - 1) len else start + chunk_size;

        //Expand slice with overlap (except at file edges)
        const s = if (i == 0) 0 else start - ov;
        const e = if (i == T - 1) len else @min(len, end + ov);

        //Core window is the non-overlap part inside the slice
        const core_s = start - s;
        const core_e = end - s;

        works[i] = .{
            .buf = file_buf[s..e],
            .base_offset = s,
            .core_start = core_s,
            .core_end = core_e,
            .enc_ascii = cfg.enc_ascii,
            .enc_utf16le = cfg.enc_utf16le,
            .enc_utf16be = cfg.enc_utf16be,
        };

        start = end;
    }

    return works;
}
