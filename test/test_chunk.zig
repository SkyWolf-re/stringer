const std = @import("std");
const types = @import("types");
const chunk = @import("chunk");

fn ovAscii(min_len: usize, null_only: bool) usize {
    const base: usize = if (min_len > 0) min_len - 1 else @as(usize, 0);
    return base + @as(usize, @intFromBool(null_only));
}

fn ovUtf16(min_len: usize, null_only: bool) usize {
    const base: usize = if (min_len > 0) (min_len - 1) * 2 else @as(usize, 0);
    return base + (2 * @as(usize, @intFromBool(null_only)));
}

fn maxOv(cfg: *const types.Config) usize {
    var m: usize = 0;
    if (cfg.enc_ascii) m = @max(m, ovAscii(cfg.min_len, cfg.null_only));
    if (cfg.enc_utf16le) m = @max(m, ovUtf16(cfg.min_len, cfg.null_only));
    if (cfg.enc_utf16be) m = @max(m, ovUtf16(cfg.min_len, cfg.null_only));
    return m;
}

fn baseCfg() types.Config {
    var c = types.Config{};
    c.min_len = 6;
    c.enc_ascii = true;
    c.enc_utf16le = true; // exercise max overlap path
    c.null_only = true;
    return c;
}

test "chunk: tiny file -> single chunk, core == full" {
    var A = std.heap.page_allocator;
    var cfg = types.Config{};
    cfg.min_len = 5;
    cfg.enc_ascii = true;
    cfg.enc_utf16le = false;
    cfg.enc_utf16be = false;
    cfg.null_only = false;

    const file_len: usize = 7; // Tiny ahh
    const tile_hint: usize = 1 << 20; // 1 MiB

    const tiles = try chunk.makeChunks(A, file_len, &cfg, tile_hint);
    defer A.free(tiles);

    try std.testing.expectEqual(@as(usize, 1), tiles.len);
    const t = tiles[0];
    try std.testing.expectEqual(@as(usize, 0), t.start);
    try std.testing.expectEqual(file_len, t.end);
    try std.testing.expectEqual(@as(usize, 0), t.core_start);
    try std.testing.expectEqual(file_len, t.core_end);
    try std.testing.expect(t.core_end > t.core_start);
}

test "chunk: two+ tiles have overlap; cores butt together without gaps or dupes" {
    var A = std.heap.page_allocator;

    var cfg = types.Config{};
    cfg.min_len = 6;
    cfg.enc_ascii = true;
    cfg.enc_utf16le = true; //both on -> take max overlap
    cfg.enc_utf16be = false;
    cfg.null_only = true;

    const ov = maxOv(&cfg);

    const tile_hint: usize = 64 * 1024; // ≥ 32 KiB floor
    const file_len: usize = tile_hint * 3 + 123; // ensures 4 tiles (last partial)

    const tiles = try chunk.makeChunks(A, file_len, &cfg, tile_hint);
    defer A.free(tiles);

    try std.testing.expect(tiles.len >= 2);

    try std.testing.expectEqual(@as(usize, 0), tiles[0].start);
    try std.testing.expectEqual(file_len, tiles[tiles.len - 1].end);

    const covered_start: usize = tiles[0].core_start;
    try std.testing.expectEqual(@as(usize, 0), covered_start);

    var i: usize = 0;
    while (i < tiles.len) : (i += 1) {
        const t = tiles[i];

        try std.testing.expect(t.core_end > t.core_start);
        try std.testing.expect(t.core_start >= t.start);
        try std.testing.expect(t.core_end <= t.end);

        if (i == 0) {
            try std.testing.expectEqual(@as(usize, 0), t.core_start);
        }
        if (i == tiles.len - 1) {
            try std.testing.expectEqual(file_len, t.core_end);
        }

        //Adjacent cores must butt exactly: end of previous == start of next
        if (i + 1 < tiles.len) {
            const next = tiles[i + 1];

            // There must be some overlap region (tile-level) equal to computed ov
            // Note: tile overlap can be larger when near file edges; so we just assert >=
            try std.testing.expect(t.end >= next.start);
            try std.testing.expect((t.end - next.start) >= ov);

            //No duplicate core range: cores should not overlap and no gaps
            try std.testing.expectEqual(t.core_end, next.core_start);
        }
    }
}

test "chunk: overlap size respects encoding + null_only" {
    var A = std.heap.page_allocator;

    //Case 1: ASCII only, null_only=false
    {
        var cfg = types.Config{};
        cfg.min_len = 5;
        cfg.enc_ascii = true;
        cfg.enc_utf16le = false;
        cfg.enc_utf16be = false;
        cfg.null_only = false;

        const tiles = try chunk.makeChunks(A, 128, &cfg, 32);
        defer A.free(tiles);

        if (tiles.len >= 2) {
            const t0 = tiles[0];
            const t1 = tiles[1];
            const ov = t0.end - t1.start;
            try std.testing.expectEqual(ovAscii(cfg.min_len, cfg.null_only), ov);
        }
    }

    // Case 2: UTF-16LE only, null_only=true
    {
        var cfg = types.Config{};
        cfg.min_len = 4;
        cfg.enc_ascii = false;
        cfg.enc_utf16le = true;
        cfg.enc_utf16be = false;
        cfg.null_only = true;

        const tiles = try chunk.makeChunks(A, 128, &cfg, 32);
        defer A.free(tiles);

        if (tiles.len >= 2) {
            const t0 = tiles[0];
            const t1 = tiles[1];
            const ov = t0.end - t1.start;
            try std.testing.expectEqual(ovUtf16(cfg.min_len, cfg.null_only), ov);
        }
    }

    // Case 3: both encodings enabled -> max of the two overlaps
    {
        var cfg = types.Config{};
        cfg.min_len = 7;
        cfg.enc_ascii = true;
        cfg.enc_utf16le = true;
        cfg.enc_utf16be = false;
        cfg.null_only = false;

        const tiles = try chunk.makeChunks(A, 256, &cfg, 64);
        defer A.free(tiles);

        if (tiles.len >= 2) {
            const t0 = tiles[0];
            const t1 = tiles[1];
            const ov = t0.end - t1.start;
            try std.testing.expectEqual(maxOv(&cfg), ov);
        }
    }
}

test "auto tiles: picks reasonable size and makes >=2 tiles for big files" {
    var A = std.heap.page_allocator;

    var cfg = baseCfg();
    // Big file: auto should not collapse to 1 tile
    const file_len: usize = 64 * 1024 * 1024; // 64 MiB

    const tiles = try chunk.makeChunks(A, file_len, &cfg, 0); // 0 -> auto
    defer A.free(tiles);

    try std.testing.expect(tiles.len >= 2);

    // Edges clamped
    try std.testing.expectEqual(@as(usize, 0), tiles[0].start);
    try std.testing.expectEqual(file_len, tiles[tiles.len - 1].end);

    // Cores butt exactly (no gaps/dupes)
    var i: usize = 0;
    while (i < tiles.len) : (i += 1) {
        const t = tiles[i];
        try std.testing.expect(t.core_end > t.core_start);
        try std.testing.expect(t.core_start >= t.start);
        try std.testing.expect(t.core_end <= t.end);
        if (i + 1 < tiles.len) {
            const n = tiles[i + 1];
            try std.testing.expectEqual(t.core_end, n.core_start);
            try std.testing.expect(t.end >= n.start); //there is overlap
        }
    }
}

test "auto tiles: small file stays single tile" {
    var A = std.heap.page_allocator;

    var cfg = baseCfg();
    const file_len: usize = 8 * 1024; // 8 KiB < floor

    const tiles = try chunk.makeChunks(A, file_len, &cfg, 0); // auto
    defer A.free(tiles);

    try std.testing.expectEqual(@as(usize, 1), tiles.len);
    const t = tiles[0];
    try std.testing.expectEqual(@as(usize, 0), t.start);
    try std.testing.expectEqual(file_len, t.end);
    try std.testing.expectEqual(@as(usize, 0), t.core_start);
    try std.testing.expectEqual(file_len, t.core_end);
}

test "auto tiles: respects large overlap (tile core >> overlap)" {
    var A = std.heap.page_allocator;

    var cfg = baseCfg();
    cfg.min_len = 128; //forces a big required overlap
    cfg.null_only = true;

    const file_len: usize = 32 * 1024 * 1024; // 32 MiB

    const tiles = try chunk.makeChunks(A, file_len, &cfg, 0);
    defer A.free(tiles);

    //we assert ">>" by checking >= 8*ov
    const ov_ascii = (cfg.min_len - 1) + @as(usize, @intFromBool(cfg.null_only));
    const ov_utf16 = 2 * (cfg.min_len - 1) + 2 * @as(usize, @intFromBool(cfg.null_only));
    const ov = @max(ov_ascii, ov_utf16);

    for (tiles) |t| {
        const core_sz = t.core_end - t.core_start;
        try std.testing.expect(core_sz >= 8 * ov);
    }
}
