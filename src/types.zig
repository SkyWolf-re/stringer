//! types.zig
//!
//! Author: skywolf
//! Date: 2025-09-28
//!
//! Canonical shared types for the string scanner
//! - Defines the configuration struct (`Config`) with safe defaults and a
//!   `validate()` routine to catch bad CLI inputs early
//! - Defines the `Kind` enum (detector type) and the `Hit` metadata struct
//!   used by emitters/printers
//! - No globals; all data passed explicitly to keep threading safe
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

    pub fn validate(self: *const Config) !void {
        if (self.min_len < 2) return error.MinLenTooSmall;
        if (!self.enc_ascii and !self.enc_utf16le and !self.enc_utf16be)
            return error.NoEncodingsSelected;
        if (self.cap_run_bytes == 0) return error.InvalidCap;
    }
};

pub const Hit = struct {
    offset: u64, //absolute file byte offset (NOT RVA)
    kind: Kind,
    chars: usize, //ASCII: bytes; UTF-16: 16-bit code units
    //text is printed by the emitter directly from a slice, so no need to store it here
};
