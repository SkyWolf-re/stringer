const std = @import("std");
const types = @import("types");
const emit = @import("emit");
const chunk = @import("chunk");
const detect_utf16 = @import("detect_utf16");
const helper = @import("test_helpers");

fn makeUtf16le(alloc: std.mem.Allocator, ascii_bytes: []const u8, with_null: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    for (ascii_bytes) |b| {
        try out.append(alloc, b);
        try out.append(alloc, 0); //hi byte
    }
    if (with_null) {
        try out.append(alloc, 0);
        try out.append(alloc, 0);
    }
    return try out.toOwnedSlice(alloc);
}

fn runUtf16Once(
    alloc: std.mem.Allocator,
    buf: []const u8,
    cfg_in: types.Config,
    base_offset: usize,
    core_start: usize,
    core_end: usize,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var cfg = cfg_in;
    cfg.json = true;

    const w = out.writer(alloc);
    const Writer = @TypeOf(w);
    const Printer = emit.SafePrinter(Writer);
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = alloc };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_utf16.scanUtf16le(Writer, &cfg, base_offset, core_start, core_end, buf, &pr);

    return try out.toOwnedSlice(alloc);
}

fn runOnce(
    alloc: std.mem.Allocator,
    buf: []const u8,
    cfg_in: types.Config,
    base_offset: usize,
    core_start: usize,
    core_end: usize,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(alloc);

    var cfg = cfg_in;
    cfg.json = true;

    const w = out.writer(alloc);
    const Writer = @TypeOf(w);
    const Printer = emit.SafePrinter(Writer);
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = alloc };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_utf16.scanUtf16le(Writer, &cfg, base_offset, core_start, core_end, buf, &pr);

    return try out.toOwnedSlice(alloc);
}

fn putUtf16le(dst: []u8, pos: usize, s: []const u8, nulterm: bool) void {
    var p = pos;
    for (s) |ch| {
        dst[p] = ch;
        dst[p + 1] = 0x00;
        p += 2;
    }
    if (nulterm and p + 1 < dst.len) {
        dst[p] = 0x00;
        dst[p + 1] = 0x00;
    }
}

test "utf16le basic run emits correct kind/len/text" {
    var gpa = std.heap.page_allocator;

    const s = "Hello";
    const data = try makeUtf16le(gpa, s, false);
    defer gpa.free(data);

    const cfg = types.Config{
        .min_len = 3,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw = try runOnce(gpa, data, cfg, 0, 0, data.len);
    defer gpa.free(raw);

    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"utf16le\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"len\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"offset\":0") != null);
}

test "utf16le null_only suppresses without terminator, emits with terminator" {
    var gpa = std.heap.page_allocator;

    const s = "FUCKME";
    const without = try makeUtf16le(gpa, s, false);
    defer gpa.free(without);
    const withterm = try makeUtf16le(gpa, s, true);
    defer gpa.free(withterm);

    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = true,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw1 = try runOnce(gpa, without, cfg, 0, 0, without.len);
    defer gpa.free(raw1);

    try std.testing.expectEqual(@as(usize, 0), raw1.len);

    const raw2 = try runOnce(gpa, withterm, cfg, 0, 0, withterm.len);
    defer gpa.free(raw2);
    try std.testing.expect(std.mem.indexOf(u8, raw2, "\"text\":\"FUCKME\"") != null);
}

test "utf16le core window prevents duplicate by start-outside" {
    var gpa = std.heap.page_allocator;

    const s = "Hi";
    const data = try makeUtf16le(gpa, s, true);
    defer gpa.free(data);

    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    //run starts at 0; core starts at 1 -> should suppress
    const raw = try runOnce(gpa, data, cfg, 0, 1, data.len);
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(usize, 0), raw.len);
}

test "utf16le cap_run_bytes triggers early emit" {
    var gpa = std.heap.page_allocator;

    const s = "ABCD"; // 4 chars -> 8 bytes
    const data = try makeUtf16le(gpa, s, false);
    defer gpa.free(data);

    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 6, // emit when chars*2 >= 6, i.e. at 3 chars
        .threads = 1,
    };

    const raw = try runOnce(gpa, data, cfg, 0, 0, data.len);
    defer gpa.free(raw);

    try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"ABC\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"len\":3") != null);
}

test "UTF-16LE --null-only: terminator in overlap emits once" {
    var A = std.heap.page_allocator;

    const word = "HELLO";
    const data = try makeUtf16le(A, word, true); //includes 0x0000 at the end
    defer A.free(data);

    var cfg = types.Config{
        .min_len = 3,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = true,
        .cap_run_bytes = 4096,
        .threads = 2,
    };
    cfg.json = true;

    const works = try chunk.makeChunks(A, data.len, &cfg, 1 << 20);
    defer A.free(works);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    for (works) |wo| {
        const slice = data[wo.start..wo.end];
        const core_s = wo.core_start - wo.start;
        const core_e = wo.core_end - wo.start;

        try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, wo.start, core_s, core_e, slice, &pr);
    }
    const raw = try out.toOwnedSlice(A);
    defer A.free(raw);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0 and std.mem.indexOf(u8, ln, "\"text\":\"HELLO\"") != null)
            count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "UTF-16LE threads=1 vs chunked equivalence (sorted by offset)" {
    var A = std.heap.page_allocator;

    const word = "MADAFAKA";
    const data = try makeUtf16le(A, word, false);
    defer A.free(data);

    var cfg = types.Config{
        .min_len = 3,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 2,
    };

    cfg.json = true;

    const raw1 = try runUtf16Once(A, data, cfg, 0, 0, data.len);
    defer A.free(raw1);

    const works = try chunk.makeChunks(A, data.len, &cfg, 1 << 20);
    defer A.free(works);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    for (works) |wo| {
        const slice = data[wo.start..wo.end];
        const core_s = wo.core_start - wo.start;
        const core_e = wo.core_end - wo.start;

        try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, wo.start, core_s, core_e, slice, &pr);
    }
    const raw2 = try out.toOwnedSlice(A);
    defer A.free(raw2);

    const s1 = try helper.sortJsonByOffset(A, raw1);
    defer A.free(s1);
    const s2 = try helper.sortJsonByOffset(A, raw2);
    defer A.free(s2);
    try std.testing.expectEqual(s1.len, s2.len);

    const c1 = try helper.concatWithNewlines(A, s1);
    defer A.free(c1);
    const c2 = try helper.concatWithNewlines(A, s2);
    defer A.free(c2);
    try std.testing.expectEqualSlices(u8, c1, c2);
}

test "UTF-16LE: odd junk bytes between pairs break the run (no hit)" {
    var A = std.heap.page_allocator;

    // S\0 0xAA e\0 0xBB r\0 0xCC v\0 0xDD e\0 0xEE r\0
    // The extra single bytes (0xAA, 0xBB, …) break contiguity
    const bad = [_]u8{
        'S', 0x00, 0xAA,
        'e', 0x00, 0xBB,
        'r', 0x00, 0xCC,
        'v', 0x00, 0xDD,
        'e', 0x00, 0xEE,
        'r', 0x00,
    };

    var cfg = types.Config{
        .min_len = 6, // "Server" has 6 chars
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
        .json = true, // easy substring assertions
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, 0, 0, bad.len, bad[0..], &pr);

    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    //No hit for "Server" because pairs are not contiguous
    try std.testing.expect(std.mem.indexOf(u8, joined, "\"text\":\"Server\"") == null);

    var total_lines: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0) total_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), total_lines);
}

test "UTF-16LE: contiguous ASCII pairs emit one hit 'Server'" {
    var A = std.heap.page_allocator;

    // Proper contiguous UTF-16LE for "Server"
    const good = [_]u8{
        'S', 0x00, 'e', 0x00, 'r', 0x00, 'v', 0x00, 'e', 0x00, 'r', 0x00,
    };

    var cfg = types.Config{
        .min_len = 6,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
        .json = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, 0, 0, good.len, good[0..], &pr);

    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    // One hit with text "Server"
    var hits: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        if (std.mem.indexOf(u8, ln, "\"text\":\"Server\"") != null) hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hits);

    //And len=6 should be present
    try std.testing.expect(std.mem.indexOf(u8, joined, "\"len\":6") != null);
}

test "UTF-16LE: leading single junk byte misaligns pairs (no hit)" {
    var A = std.heap.page_allocator;

    // 0xAA followed by proper pairs for "Server"
    // Valid pairs start at index 1 (odd), but detector checks 0,2,4,... so it misses them
    const misaligned = [_]u8{
        0xAA,
        'S',
        0x00,
        'e',
        0x00,
        'r',
        0x00,
        'v',
        0x00,
        'e',
        0x00,
        'r',
        0x00,
    };

    var cfg = types.Config{
        .min_len = 6,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
        .json = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, 0, 0, misaligned.len, misaligned[0..], &pr);

    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    // No "Server" hit because pairs are all off-by-one relative to the detector’s 2-byte stride
    try std.testing.expect(std.mem.indexOf(u8, joined, "\"text\":\"Server\"") == null);

    //Optional: confirm zero UTF-16LE hits total
    var total: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0) total += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), total);
}

test "UTF-16LE: 1 MiB high-entropy noise, min_len=6 -> zero hits" {
    var A = std.heap.page_allocator;

    // 1 MiB buffer with pseudo-random bytes
    // Sanitize: ensure NO valid UTF-16LE ASCII pairs.
    // Make every hi-byte non-zero so (lo, hi) never equals (printable, 0).
    const buf = try A.alloc(u8, 1 << 20);
    defer A.free(buf);
    helper.fillPseudoRandom(buf, 420024);
    helper.breakUtf16leAsciiPairs(buf);

    var cfg = types.Config{
        .min_len = 6,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .json = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, 0, 0, buf.len, buf, &pr);

    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "UTF-16LE honors core window: only last 1 KiB is emitted" {
    var A = std.heap.page_allocator;

    const total_len: usize = 4096; // 4 KiB buffer
    var buf = try A.alloc(u8, total_len);
    defer A.free(buf);
    @memset(buf, 0xAA); // non-ASCII noise

    // Core window = last KiB
    const core_start: usize = total_len - 1024;
    const core_end: usize = total_len;

    //Helper: writes ASCII-range UTF-16LE "WORD" with trailing 0x0000 terminator
    const put_u16le_run = struct {
        fn write(bufa: []u8, start: usize, text: []const u8) void {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                bufa[start + 2 * i + 0] = text[i]; // lo
                bufa[start + 2 * i + 1] = 0x00; // hi
            }
            // NUL terminator (two zero bytes) required when null_only = true
            bufa[start + 2 * text.len + 0] = 0x00;
            bufa[start + 2 * text.len + 1] = 0x00;
        }
    }.write;

    // Two tail runs fully inside core window
    const tail1 = "TAILA";
    const tail2 = "TAILB";
    const t1_off = core_start + 16; // aligned generously inside window
    const t2_off = core_start + 400;

    // Guard before each run with junk byte so there’s no accidental merge
    buf[t1_off - 1] = 0xFF;
    buf[t2_off - 1] = 0xFF;

    put_u16le_run(buf, t1_off, tail1);
    put_u16le_run(buf, t2_off, tail2);

    //A couple of runs outside the window that must NOT be emitted
    const head = "HEAD";
    const mid = "MIDDLE";
    const h_off: usize = 64; // well before core_start
    const m_off: usize = 1800; // still before core_start
    buf[h_off - 1] = 0xFF;
    put_u16le_run(buf, h_off, head);
    buf[m_off - 1] = 0xFF;
    put_u16le_run(buf, m_off, mid);

    var cfg = types.Config{
        .min_len = 4,
        .enc_ascii = false,
        .enc_utf16le = true,
        .enc_utf16be = false,
        .null_only = true, // <-- needs 0x00 0x00 after the run
        .cap_run_bytes = 4096,
        .threads = 1,
        .json = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);

    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_utf16.scanUtf16le(@TypeOf(w), &cfg, 0, core_start, core_end, buf, &pr);

    const json = try out.toOwnedSlice(A);
    defer A.free(json);

    //offsets fall inside the core window
    var hits: usize = 0;
    var it = std.mem.splitScalar(u8, json, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;

        //`"offset":<num>`
        const key = "\"offset\":";
        const j = std.mem.indexOf(u8, line, key) orelse continue;
        var k = j + key.len;
        while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
        const s = k;
        while (k < line.len and (line[k] >= '0' and line[k] <= '9')) : (k += 1) {}
        const off = try std.fmt.parseUnsigned(usize, line[s..k], 10);

        try std.testing.expect(off >= core_start);
        try std.testing.expect(off < core_end);
        hits += 1;
    }

    try std.testing.expectEqual(@as(usize, 2), hits);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"TAILA\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"TAILB\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"HEAD\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"MIDDLE\"") == null);
}
