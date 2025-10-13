//! detect_utf16.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! UTF-16 detectors (MVP implements LE scanning)
//! - Detects runs of UTF-16LE ASCII-range code units: (lo in 0x20..0x7E or \t \n \r) with hi==0
//! - Emits only if run length >= min_len and, if requested, a 0x0000 terminator follows
//! - De-dupes across threads by emitting only when the run *start* lies inside
//!   the caller-provided core window [core_start, core_end)
//!
//! Notes:
//! - `cap_run_bytes` is enforced in *bytes* (so `chars*2 >= cap_run_bytes`)
//! - At EOF, `--null-only` requires the terminator to be present; otherwise the run is dropped
//! - UTF-16BE support can be added with a mirror scanner; we keep the BE predicate here for later

const std = @import("std");
const types = @import("types");
const ascii = @import("detect_ascii");
const emit = @import("emit");

pub inline fn isUtf16leAscii(lo: u8, hi: u8) bool {
    return hi == 0 and ascii.isPrintableAscii(lo);
}

pub inline fn isUtf16beAscii(lo: u8, hi: u8) bool {
    return lo == 0 and ascii.isPrintableAscii(hi);
}

/// Scan UTF-16LE runs and emit via printer
/// Only emit hits whose start index lies in [core_start, core_end]
pub fn scanUtf16le(
    comptime Printer: type,
    cfg: *const types.Config,
    base_offset: usize,
    core_start: usize,
    core_end: usize,
    buf: []const u8,
    pr: *Printer,
) !void {
    var i: usize = 0;
    var chars: usize = 0;
    var start: usize = 0;

    while (i + 1 < buf.len) {
        const lo = buf[i];
        const hi = buf[i + 1];

        if (isUtf16leAscii(lo, hi)) {
            if (chars == 0) start = i;
            chars += 1;
            i += 2;

            //Cap measured in bytes; emit early and reset if capped
            if (chars * 2 >= cfg.cap_run_bytes) {
                if (chars >= cfg.min_len and start >= core_start and start < core_end) {
                    try pr.emitUtf16le(base_offset + start, chars, buf[start..i]);
                }
                chars = 0;
            }
            continue;
        }

        //End of a run
        if (chars >= cfg.min_len) {
            const has_terminator = (i + 1 < buf.len and buf[i] == 0 and buf[i + 1] == 0);
            if (!cfg.null_only or has_terminator) {
                if (start >= core_start and start < core_end) {
                    try pr.emitUtf16le(base_offset + start, chars, buf[start..i]);
                }
            }
        }
        chars = 0;
        i += 2; //stay on 16-bit boundaries
    }

    //Trailing run at EOF
    if (chars >= cfg.min_len) {
        const has_terminator = (i + 1 < buf.len and buf[i] == 0 and buf[i + 1] == 0);
        if (!cfg.null_only or has_terminator) {
            if (start >= core_start and start < core_end) {
                try pr.emitUtf16le(base_offset + start, chars, buf[start..i]);
            }
        }
    }
}
