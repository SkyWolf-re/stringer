const std = @import("std");
const types = @import("types");
const emit = @import("emit");
const helper = @import("test_helpers");

test "emitAscii(JSON): u64 offset + escaping + newline" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = true;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const off: u64 = 0x0123_4567_89AB_CDEF;
    const text = "\"\\\n\t" ++ [_]u8{0x07} ++ "Z";

    try pr.emitAscii(off, text.len, text);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    // newline present
    try std.testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    // numeric "offset" equals `off`
    const got_off = try helper.jsonFindUint(line, "offset");
    try std.testing.expectEqual(off, got_off);

    var dec_buf: [32]u8 = undefined;
    const dec = try std.fmt.bufPrint(&dec_buf, "{d}", .{off}); // decimal u64

    var needle_buf: [48]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "\"offset\":{s}", .{dec});

    try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"ascii\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"len\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"text\":\"\\\"\\\\\\n\\t\\u0007Z\"") != null);
}

test "emitAscii(JSON): handles u64::max offset and has no raw control bytes" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = true;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const off: u64 = 0xFFFF_FFFF_FFFF_FFFF;
    const text = "Hello\n\tWorld"; // contains controls that must be escaped in JSON
    try pr.emitAscii(off, text.len, text);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    // newline present
    try std.testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    // numeric offset equals exactly off
    const got_off = try helper.jsonFindUint(line, "offset");
    try std.testing.expectEqual(off, got_off);

    // ensuring there are no raw control bytes < 0x20 in the JSON line (excluding final '\n')
    for (line[0 .. line.len - 1]) |b| {
        try std.testing.expect(b >= 0x20 or b == '\n' or b == '\r'); // JSON escapes take care of others
    }
}

test "emitAscii(JSON): cap_run_bytes truncates JSON text payload" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = true;
    cfg.cap_run_bytes = 5;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const long = "AAAAAAAAAAAA"; // 12 'A's
    try pr.emitAscii(0x22, long.len, long);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    //reported len remains original
    try std.testing.expect(std.mem.indexOf(u8, line, "\"len\":12") != null);

    //payload is exactly 5 'A's inside quotes
    try std.testing.expect(std.mem.indexOf(u8, line, "\"text\":\"AAAAA\"") != null);
}

test "emitAscii(text): 16-hex offset, kind column, len, quoted/escaped" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = false;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const text = "A\nB\"\\";
    const off: u64 = 0xABCDEF01_23456789;

    try pr.emitAscii(off, text.len, text);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    //starts with 16 hex digits (lowercase) + two spaces
    const hex = line[0..16];
    const got = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(off, got);

    //Has kind column and length
    try std.testing.expect(std.mem.indexOf(u8, line, "ascii   ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "len=5") != null);

    //Text is quoted with escapes (\n => \\n, " => \", \\ => \\)
    try std.testing.expect(std.mem.indexOf(u8, line, "\"A\\nB\\\"\\\\\"") != null);

    //newline-terminated
    try std.testing.expect(line[line.len - 1] == '\n');
}

test "emitAscii(text): cap_run_bytes truncates payload, len field remains original" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = false;
    cfg.cap_run_bytes = 8; //mall to observe truncation

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const long = "AAAAAAAAAAAA"; // 12 'A's, no escaping in text mode
    try pr.emitAscii(0x10, long.len, long);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    //reported len is the caller-provided value (12)
    try std.testing.expect(std.mem.indexOf(u8, line, "len=12") != null);

    //payload is quoted and truncated to 8 characters
    try std.testing.expect(std.mem.indexOf(u8, line, "\"AAAAAAAA\"") != null);
}

test "emitUtf16le(JSON): u64 offset + ASCII-range decode + escaping + newline" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = true;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    // UTF-16LE region for:  A \n B \u0007 Z
    const region = [_]u8{
        'A',  0x00,
        0x0A, 0x00,
        'B',  0x00,
        0x07, 0x00,
        'Z',  0x00,
    };
    const chars: usize = 5;
    const off: u64 = 0x00DE_ADBE_EFAB_C123;

    try pr.emitUtf16le(off, chars, &region);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    //newline present
    try std.testing.expect(line.len > 0 and line[line.len - 1] == '\n');

    //numeric "offset" equals off
    const got_off = try helper.jsonFindUint(line, "offset");
    try std.testing.expectEqual(off, got_off);

    //kind/len present
    try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"utf16le\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"len\":5") != null);

    //decoded & escaped text
    try std.testing.expect(std.mem.indexOf(u8, line, "\"text\":\"A\\nB\\u0007Z\"") != null);
}

test "emitUtf16le(text): 16-hex offset, kind, len, quoted/escaped" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = false;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const region = [_]u8{
        'A',  0x00,
        0x0A, 0x00,
        'B',  0x00,
        0x07, 0x00,
        'Z',  0x00,
    };
    const chars: usize = 5;
    const off: u64 = 0xABCDEF01_23456789;

    try pr.emitUtf16le(off, chars, &region);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    // parses hex prefix to verify offset exactly
    const hex = line[0..16];
    const got_off = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(off, got_off);

    // structure
    try std.testing.expect(line[line.len - 1] == '\n');
    try std.testing.expect(std.mem.indexOf(u8, line, "utf16le ") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "len=5") != null);

    // payload is quoted; \n is escaped, BEL (0x07) is raw in text mode
    const want = "\"A\\nB" ++ [_]u8{0x07} ++ "Z\"";
    try std.testing.expect(std.mem.indexOf(u8, line, want) != null);
}

test "emitUtf16le(text): cap_run_bytes truncates, raw BEL (0x07) stays raw" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = false;
    cfg.cap_run_bytes = 4;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    // UTF-16LE for: A \n B \u0007 Z  (5 chars)
    const region = [_]u8{
        'A', 0x00, 0x0A, 0x00, 'B', 0x00, 0x07, 0x00, 'Z', 0x00,
    };
    try pr.emitUtf16le(0xABCDEF, 5, &region);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    //for (line, 0..) |b, i| {
    //  if (i % 16 == 0) std.debug.print("\n", .{});
    //std.debug.print("{x:0>2} ", .{b});
    //}
    //std.debug.print("\n", .{});

    // payload: truncated to 4 visible bytes, newline escaped, BEL raw
    const want = "\"A\\nB" ++ [_]u8{0x07} ++ "\"";
    try std.testing.expect(std.mem.indexOf(u8, line, want) != null);
}

test "emitUtf16le(text): prefix hex parses back to original u64 offset" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.json = false;

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    const off: u64 = 0xDEAD_BEEF_F00D_FACE;
    const region = [_]u8{ 'X', 0, 'Y', 0 };
    try pr.emitUtf16le(off, 2, &region);

    const line = try out.toOwnedSlice(A);
    defer A.free(line);

    const hex = line[0..16];
    const got = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(off, got);
}
