const std = @import("std");

/// Parses the numeric value after `"offset":` in a JSON line
/// Returns 0 if not found/parseable (good enough for test sorting I guess)
pub fn parseOffset(line: []const u8) usize {
    if (std.mem.indexOf(u8, line, "\"offset\":")) |i| {
        var j: usize = i + 9;
        while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {}
        return std.fmt.parseUnsigned(usize, line[i + 9 .. j], 10) catch 0;
    }
    return 0;
}

/// Splits `raw` JSONL into lines, drops empties, and returns a slice sorted by offset
pub fn sortJsonByOffset(alloc: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).empty;
    errdefer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| if (ln.len != 0) try lines.append(alloc, ln);

    const Slice = []const u8;
    const arr = try lines.toOwnedSlice(alloc);

    std.sort.block(Slice, arr, {}, struct {
        fn less(_: void, a: Slice, b: Slice) bool {
            return parseOffset(a) < parseOffset(b);
        }
    }.less);

    return arr;
}

/// Joins lines with `\n` back into a single buffer (owned by `alloc`)
pub fn concatWithNewlines(alloc: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);
    for (lines) |ln| {
        try out.appendSlice(alloc, ln);
        try out.append(alloc, '\n');
    }
    return try out.toOwnedSlice(alloc);
}

/// Find `"key":<number>` and parse the number (unsigned base10)
pub fn jsonFindUint(line: []const u8, key: []const u8) !u64 {
    const needle = try std.mem.concat(std.heap.page_allocator, u8, &.{ "\"", key, "\":" });
    defer std.heap.page_allocator.free(needle);

    const pos = std.mem.indexOf(u8, line, needle) orelse return error.KeyNotFound;
    var i: usize = pos + needle.len;
    // skip whitespace
    while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
    // number starts at i; ends at first non-digit
    const start = i;
    while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {}
    if (i == start) return error.BadNumber;
    return try std.fmt.parseInt(u64, line[start..i], 10);
}

/// Simple 64-bit LCG for deterministic pseudo-random bytes (fast, no deps).
/// If `seed` is 0, a fixed non-zero seed is used.
pub fn fillPseudoRandom(buf: []u8, seed: u64) void {
    var x: u64 = if (seed == 0) 0x9E3779B97F4A7C15 else seed; // golden-ratio-ish
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        // LCG(64): x = a*x + c  (Numerical Recipes constants), wraping LCG step to avoid overflow
        x = x *% 6364136223846793005 +% 1;
        buf[i] = @truncate(x >> 24);
    }
}

/// Force all bytes to be non-printable ASCII (guarantees 0 ASCII hits).
pub fn scrubToNonPrintableAscii(buf: []u8) void {
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const b = buf[i];
        const printable =
            (b >= 0x20 and b <= 0x7E) or b == '\t' or b == '\n' or b == '\r';
        if (printable) buf[i] = 0x01; // harmless control; breaks runs
    }
}

/// Ensure NO valid UTF-16LE ASCII pairs by forcing every hi byte != 0.
pub fn breakUtf16leAsciiPairs(buf: []u8) void {
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        buf[i + 1] = 0xFF; // hi ≠ 0 -> detector won't accept pair
    }
}
