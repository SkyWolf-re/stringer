const std = @import("std");
const types = @import("types");
const emit = @import("emit");
const chunk = @import("chunk");
const detect_ascii = @import("detect_ascii");
const helper = @import("test_helpers");

//return the emitted bytes (JSON lines if cfg.json=true)
fn runAscii(
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
    cfg.json = true; //JSON lines cuz easier to assert with substrings

    const w = out.writer(alloc);
    const Writer = @TypeOf(w);
    const Printer = emit.SafePrinter(Writer);
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = alloc };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));
    try detect_ascii.scanAscii(Writer, &cfg, base_offset, core_start, core_end, buf, &pr);

    return try out.toOwnedSlice(alloc);
}

test "ASCII basic run emits one record with correct len/text/offset" {
    var gpa = std.heap.page_allocator;

    //"Hell" + non-printable 0x01 to terminate run
    const data = "Hell" ++ [_]u8{0x01} ++ "lehoo";
    const cfg = types.Config{
        .min_len = 3,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw = try runAscii(gpa, data, cfg, 0, 0, data.len);
    defer gpa.free(raw);

    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"ascii\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"len\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"Hell\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"offset\":0") != null);
}

test "ASCII null_only drops run without NULL, emits when NULL present" {
    var gpa = std.heap.page_allocator;

    const s = "CraK";
    const without = s; // no terminator
    const withnul = s ++ [_]u8{0x00}; //NULL terminator

    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = true, //requires \0 just after run
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    //without NUL -> no output
    {
        const raw = try runAscii(gpa, without, cfg, 0, 0, without.len);
        defer gpa.free(raw);
        try std.testing.expectEqual(@as(usize, 0), raw.len);
    }

    // with NUL -> one record
    {
        const raw = try runAscii(gpa, withnul, cfg, 0, 0, withnul.len);
        defer gpa.free(raw);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"CraK\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, raw, "\"len\":4") != null);
    }
}

test "ASCII core window suppresses emit when start is outside core" {
    var gpa = std.heap.page_allocator;

    //making core start at 1 so emit is suppressed
    const data = "Hi there";
    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw = try runAscii(gpa, data, cfg, 0, 1, data.len);
    defer gpa.free(raw);
    try std.testing.expectEqual(@as(usize, 0), raw.len);
}

test "ASCII cap_run_bytes triggers early emit with truncated len" {
    var gpa = std.heap.page_allocator;

    const data = "ABCDE"; //5 bytes printable
    const cfg = types.Config{
        .min_len = 2,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 3,
        .threads = 1,
    };

    const raw = try runAscii(gpa, data, cfg, 0, 0, data.len);
    defer gpa.free(raw);

    try std.testing.expect(std.mem.indexOf(u8, raw, "\"len\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"ABC\"") != null);
}

test "ASCII allows \\t, \\n, \\r inside runs" {
    var gpa = std.heap.page_allocator;

    const data = "F\tUC\r\nK";
    const cfg = types.Config{
        .min_len = 4, // F \t U C -> length >= 4
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw = try runAscii(gpa, data, cfg, 0, 0, data.len);
    defer gpa.free(raw);

    //one record containing the whole sequence (len 6)
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"kind\":\"ascii\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\"text\":\"F\\tUC\\r\\nK\"") != null);
}

test "ASCII --null-only: terminator in overlap still emits once" {
    var A = std.heap.page_allocator;

    const left = "GoodbyeWorld";
    const data = left ++ [_]u8{0} ++ "noise";
    var cfg = types.Config{
        .min_len = 5,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = true,
        .cap_run_bytes = 4096,
        .threads = 2,
    };

    cfg.json = true;

    //overlap
    const works = try chunk.makeChunks(A, data.len, &cfg, 1 << 20);
    defer A.free(works);

    var out1 = std.ArrayList(u8).empty; //aggregated JSON
    defer out1.deinit(A);
    const w = out1.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out1, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    //simulating both workers
    for (works) |wo| {
        const slice = data[wo.start..wo.end];
        const core_s = wo.core_start - wo.start;
        const core_e = wo.core_end - wo.start;

        try detect_ascii.scanAscii(@TypeOf(w), &cfg, wo.start, core_s, core_e, slice, &pr);
    }

    const joined = try out1.toOwnedSlice(A);
    defer A.free(joined);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0 and std.mem.indexOf(u8, ln, "\"text\":\"GoodbyeWorld\"") != null)
            count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "ASCII threads=1 vs chunked set of hits are equivalent (sorted by offset)" {
    var A = std.heap.page_allocator;

    const data =
        "AAAXXX" ++ [_]u8{0x01} ++
        "BBBBB" ++ [_]u8{0} ++
        "CCCCC" ++ [_]u8{0x01} ++
        "DDD";
    var cfg = types.Config{
        .min_len = 3,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 2,
    };

    cfg.json = true;

    // single “thread” run (whole buffer)
    const raw1 = try runAscii(A, data, cfg, 0, 0, data.len);
    defer A.free(raw1);

    //chunked simulation
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

        try detect_ascii.scanAscii(@TypeOf(w), &cfg, wo.start, core_s, core_e, slice, &pr);
    }
    const raw2 = try out.toOwnedSlice(A);
    defer A.free(raw2);

    //comparing byte-for-byte
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

test "ASCII randomized noise produces (almost) no hits at high min_len" {
    var A = std.heap.page_allocator;

    var rnd = std.Random.DefaultPrng.init(0x69696969);
    var rng = rnd.random();

    const buf = try A.alloc(u8, 4096);
    defer A.free(buf);
    for (buf) |*b| b.* = rng.int(u8); // random bytes

    const cfg = types.Config{
        .min_len = 20,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = false,
        .cap_run_bytes = 4096,
        .threads = 1,
    };

    const raw = try runAscii(A, buf, cfg, 0, 0, buf.len);
    defer A.free(raw);

    //it’s possible to get a long printable run but I have more chances to get laid instead
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0)
            lines += 1;
    }
    try std.testing.expect(lines <= 2);
}

test "ASCII boundary across tiles: 'ABCD' spans tiles; emit once" {
    var A = std.heap.page_allocator;

    // Non-printable (0x01) delimiters force the run to be exactly "ABCD"
    const sep = [_]u8{0x01};
    const data = sep ++ "ABCD" ++ sep;

    var cfg = types.Config{};
    cfg.min_len = 4;
    cfg.enc_ascii = true;
    cfg.enc_utf16le = false;
    cfg.enc_utf16be = false;
    cfg.json = true;

    //Indices within `data`
    const idx_A = 1; // sep[0] then 'A'
    //const idx_B = idx_A + 1;
    const idx_C = idx_A + 2; // boundary between B | C
    const ov: usize = 3; // overlap >= (min_len-1)

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    // ---- Tile 1: core ends at boundary (…B | C…)
    const t1_start: usize = 0;
    const t1_core_s: usize = 0;
    const t1_core_e: usize = idx_C; // core ends *before* 'C'
    const t1_end: usize = @min(data.len, idx_C + ov);
    try detect_ascii.scanAscii(@TypeOf(w), &cfg, t1_start, t1_core_s, t1_core_e, data[t1_start..t1_end], &pr);

    // ---- Tile 2: core starts at boundary, includes left overlap
    const t2_start: usize = if (idx_C >= ov) (idx_C - ov) else 0;
    const t2_core_s: usize = idx_C - t2_start; // 'C' is first core byte
    const t2_core_e: usize = data.len - t2_start;
    try detect_ascii.scanAscii(@TypeOf(w), &cfg, t2_start, t2_core_s, t2_core_e, data[t2_start..], &pr);

    // Expect exactly one JSON line: "text":"ABCD"
    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    var hits: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len == 0) continue;
        if (std.mem.indexOf(u8, ln, "\"text\":\"ABCD\"") != null) hits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hits);
}

test "ASCII: 1 MiB high-entropy noise, min_len=6 -> zero hits" {
    var A = std.heap.page_allocator;

    // 1 MiB buffer with pseudo-random bytes
    // Sanitize: force NON-printable so we deterministically get 0 hits.
    // If a byte is printable ASCII (or allowed ctrl), rewrite to 0x01.
    const buf = try A.alloc(u8, 1 << 20);
    defer A.free(buf);
    helper.fillPseudoRandom(buf, 696969);
    helper.scrubToNonPrintableAscii(buf);

    var cfg = types.Config{
        .min_len = 6,
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .json = true,
    };

    var out = std.ArrayList(u8).empty;
    defer out.deinit(A);
    const w = out.writer(A);
    const Printer = emit.SafePrinter(@TypeOf(w));
    const ctx = emit.Sink.Ctx{ .list = &out, .alloc = A };
    var pr = Printer.init(&cfg, w, emit.Sink.sinkArrayList(&ctx));

    try detect_ascii.scanAscii(@TypeOf(w), &cfg, 0, 0, buf.len, buf, &pr);

    const joined = try out.toOwnedSlice(A);
    defer A.free(joined);

    // Expect zero JSON lines (no hits)
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, joined, '\n');
    while (it.next()) |ln| {
        if (ln.len != 0) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), count);
}

//  Scenario:
//  - Buffer len = 3072 bytes
//  - Filled with 0x01 (non-printable) so no accidental runs
//  - ASCII strings at:
//      100:  "HEAD"    (outside tail)
//      1500: "MIDDLE"  (outside tail)
//      2500: "TAILA"   (inside last 1 KiB)
//      2800: "TAILB"   (inside last 1 KiB)
//  - core_start = len - 1024, core_end = len
//  - Expect exactly 2 hits (TAILA, TAILB), both with offset >= core_start
test "ASCII honors core window: only last 1 KiB is emitted" {
    var A = std.heap.page_allocator;

    const total_len: usize = 3072; // 3 KiB
    var buf = try A.alloc(u8, total_len);
    defer A.free(buf);
    @memset(buf, 0xAA); // noise: non-printable everywhere

    // Core window = last 1024 bytes.
    const core_start: usize = total_len - 1024;
    const core_end: usize = total_len;

    const t1_off = core_start + 10;
    const t2_off = core_start + 300;

    const t1 = "TAILA";
    const t2 = "TAILB";

    buf[t1_off - 1] = 0x01; // non-printable
    @memcpy(buf[t1_off .. t1_off + t1.len], t1);
    buf[t1_off + t1.len] = 0x00; //required when null_only = true

    buf[t2_off - 1] = 0x01;
    @memcpy(buf[t2_off .. t2_off + t2.len], t2);
    buf[t2_off + t2.len] = 0x00;

    // Also adds a couple of strings OUTSIDE the window to prove they don’t emit
    const h1_off: usize = 100;
    const h1 = "HEAD";
    buf[h1_off - 1] = 0x01;
    @memcpy(buf[h1_off .. h1_off + h1.len], h1);
    buf[h1_off + h1.len] = 0x00;

    const m1_off: usize = 1500; // still outside last 1 KiB
    const m1 = "MIDDLE";
    buf[m1_off - 1] = 0x01;
    @memcpy(buf[m1_off .. m1_off + m1.len], m1);
    buf[m1_off + m1.len] = 0x00;

    var cfg = types.Config{
        .min_len = 4, // HEAD(4), MIDDLE(6), TAILA(5), TAILB(5)
        .enc_ascii = true,
        .enc_utf16le = false,
        .enc_utf16be = false,
        .null_only = true, // <- needs the 0x00 after runs
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

    //ASCII detector over the whole buffer but restrict emits via core window
    try detect_ascii.scanAscii(@TypeOf(w), &cfg, 0, core_start, core_end, buf, &pr);

    const json = try out.toOwnedSlice(A);
    defer A.free(json);

    // Expect only the two tail hits
    var hits: usize = 0;
    var it = std.mem.splitScalar(u8, json, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try std.testing.expect(std.mem.indexOf(u8, line, "\"kind\":\"ascii\"") != null);

        // offset must be inside the core window
        const key = "\"offset\":";
        const j = std.mem.indexOf(u8, line, key) orelse return error.NoOffset;
        var k = j + key.len;
        while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
        const s = k;
        while (k < line.len and line[k] >= '0' and line[k] <= '9') : (k += 1) {}
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
