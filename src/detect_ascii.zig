//! detect_ascii.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! ASCII / “UTF-8-lite” detector
//! - Scans for runs of printable bytes (0x20..0x7E plus \t \n \r)
//! - Emits only if the run length >= min_len and (if enabled) a null terminator
//!   follows the run inside the buffer
//! - De-dupes across threads by emitting only when the run *start* lies inside
//!   the caller-provided core window [core_start, core_end)
//!
//! Notes:
//! - `cap_run_bytes` limits how many bytes we consider part of a single run here;
//!   the printer also caps output length when rendering
//! - At EOF, `--null-only` requires the terminator to be present; missing \0
//!   means “no emit”

const std = @import("std");
const types = @import("types");
const emit = @import("emit");

pub inline fn isAllowedCtrl(b: u8) bool {
    return b == '\t' or b == '\n' or b == '\r';
}

pub inline fn isPrintableAscii(b: u8) bool {
    return (b >= 0x20 and b <= 0x7E) or isAllowedCtrl(b);
}

/// Scan ASCII/“UTF-8-lite” runs and emit via printer.
/// Only emit hits whose start index lies in [core_start, core_end]
pub fn scanAscii(
    comptime Writer: type,
    cfg: *const types.Config,
    base_offset: usize,
    core_start: usize,
    core_end: usize,
    buf: []const u8,
    pr: *emit.SafePrinter(Writer),
) !void {
    var i: usize = 0;

    while (i < buf.len) {
        //Skip non-printable bytes
        while (i < buf.len and !isPrintableAscii(buf[i])) : (i += 1) {}

        const start = i;

        //Consume printable run (capped)
        while (i < buf.len and isPrintableAscii(buf[i])) : (i += 1) {
            if (i - start >= cfg.cap_run_bytes) break;
        }
        const run = i - start;

        if (run >= cfg.min_len) {
            const has_terminator = (i < buf.len and buf[i] == 0);
            if (!cfg.null_only or has_terminator) {
                if (start >= core_start and start < core_end) {
                    try pr.emitAscii(base_offset + start, run, buf[start .. start + run]);
                }
            }
        }
        // Loop continues i already at first non-printable (or cap boundary)
    }
}
