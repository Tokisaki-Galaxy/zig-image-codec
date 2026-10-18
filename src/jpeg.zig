//! JPEG decoder -> carrier bytes (Y quantized AC coefficient magnitudes).
//!
//! Baseline DCT (SOF0), Huffman-coded sequential JPEG (ITU-T T.81) decoder
//! that stops *before* IDCT / color conversion.  It recovers the quantized
//! DCT coefficients from the entropy-coded stream — the domain that survives
//! lossy re-encoding — and flattens the luminance (Y) AC band into carrier
//! bytes for the stego layer.
//!
//! ## Carrier contract
//!
//! For every 8x8 block of the first frame component (luminance), the
//! magnitudes of zig-zag AC positions 1..=32 (`BPP` = 31 values) are stored
//! block-major: `carriers[(by*blocks_x + bx)*BPP + (z-1)]`.
//!
//! A coefficient magnitude becomes a candidate iff `2 <= |coef| <= 254`;
//! otherwise the slot is zero (placeholder, never a candidate).  This keeps
//! the candidate set invariant under the encoder's +/-1 magnitude flips
//! (F5 non-shrinkability; boundaries protected by asymmetric costs).
//!
//! The dead-drop salt material is recovered from the cover's own EXIF APP1
//! segment (`exif.zig`); the decoder never relies on custom metadata.
//!
//! Unsupported variants are rejected explicitly: progressive (SOF2),
//! arithmetic-coded (SOF9..SOF14), 4-component CMYK, non-8-bit precision,
//! non-interleaved / multi-scan streams.

const std = @import("std");
const root = @import("root.zig");
const exif = @import("exif.zig");

// ── Markers ──────────────────────────────────────────────────────────────────

const M_TEM: u8 = 0x01;
const M_SOF0: u8 = 0xC0;
const M_DHT: u8 = 0xC4;
const M_SOI: u8 = 0xD8;
const M_EOI: u8 = 0xD9;
const M_SOS: u8 = 0xDA;
const M_DQT: u8 = 0xDB;
const M_DRI: u8 = 0xDD;
const M_RST0: u8 = 0xD0;
const M_RST7: u8 = 0xD7;
const M_COM: u8 = 0xFE;
const M_APP1: u8 = 0xE1;

// ── Carrier band ─────────────────────────────────────────────────────────────

/// Zig-zag AC band (exclusive of DC), inclusive bounds.
pub const AC_BAND_LO: u8 = 1;
pub const AC_BAND_HI: u8 = 32;
/// Bytes of carrier per 8x8 block.
pub const BPP: u8 = AC_BAND_HI - AC_BAND_LO + 1; // 31

/// Anti-decompression-bomb: cap on decoded blocks.
const MAX_BLOCKS: u64 = 400_000;

// ── Huffman table ────────────────────────────────────────────────────────────

const HuffTable = struct {
    min_code: [17]i32 = @splat(-1),
    max_code: [17]i32 = @splat(-1),
    val_offset: [17]u32 = @splat(0),
    symbols: [256]u8 = @splat(0),
    num_symbols: u16 = 0,
};

// ── Frame / scan info ────────────────────────────────────────────────────────

const Component = struct {
    id: u8 = 0,
    h: u8 = 1,
    v: u8 = 1,
    tq: u8 = 0,
    dc_tbl: u8 = 0,
    ac_tbl: u8 = 0,
    pred_dc: i32 = 0,
};

const Frame = struct {
    width: u16 = 0,
    height: u16 = 0,
    precision: u8 = 0,
    ncomp: u8 = 0,
    comps: [4]Component = .{ .{}, .{}, .{}, .{} },
    hmax: u8 = 1,
    vmax: u8 = 1,
};

// ── Entropy-coded bit reader (with byte stuffing / marker handling) ─────────

const BitReader = struct {
    data: []const u8,
    pos: usize,
    bit_buf: u32 = 0,
    bit_cnt: u5 = 0,

    fn fillByte(self: *BitReader) !u8 {
        while (true) {
            if (self.pos >= self.data.len) return error.Truncated;
            const b = self.data[self.pos];
            self.pos += 1;
            if (b != 0xFF) return b;
            if (self.pos >= self.data.len) return error.Truncated;
            const b2 = self.data[self.pos];
            if (b2 == 0x00) {
                // Byte-stuffed 0xFF data byte.
                self.pos += 1;
                return 0xFF;
            }
            if (b2 >= M_RST0 and b2 <= M_RST7) {
                // Restart marker: consumed here; caller handles at MCU boundary.
                self.pos += 1;
                return error.RestartMarker;
            }
            // Any other marker terminates the entropy-coded segment; the
            // marker byte itself is left un-consumed.
            return error.EndOfScan;
        }
    }

    fn readBits(self: *BitReader, n: u5) !u32 {
        while (self.bit_cnt < n) {
            const b = try self.fillByte();
            self.bit_buf = (self.bit_buf << 8) | b;
            self.bit_cnt +%= 8;
        }
        self.bit_cnt -%= n;
        const shift: u5 = self.bit_cnt;
        const mask: u32 = if (n == 32) 0xFFFF_FFFF else (@as(u32, 1) << n) - 1;
        return (self.bit_buf >> shift) & mask;
    }

    fn resetByteAligned(self: *BitReader) void {
        self.bit_buf = 0;
        self.bit_cnt = 0;
    }
};

// ── Canonical Huffman decode ────────────────────────────────────────────────

fn huffmanDecode(huf: *const HuffTable, br: *BitReader) !u8 {
    var code: u32 = 0;
    var len: usize = 1;
    while (len <= 16) : (len += 1) {
        code = (code << 1) | try br.readBits(1);
        const mn = huf.min_code[len];
        if (mn >= 0 and code >= @as(u32, @intCast(mn)) and code <= @as(u32, @intCast(huf.max_code[len]))) {
            const idx = huf.val_offset[len] + (code - @as(u32, @intCast(mn)));
            if (idx >= huf.num_symbols) return error.BadHuffman;
            return huf.symbols[idx];
        }
    }
    return error.BadHuffman;
}

// ── Block decode ─────────────────────────────────────────────────────────────

fn decodeBlock(
    huf_dc: *const HuffTable,
    huf_ac: *const HuffTable,
    comp: *Component,
    br: *BitReader,
    coef: *[64]i16,
) !void {
    @memset(coef, 0);

    // DC: differential, with category + sign-extended extra bits.
    const cat = try huffmanDecode(huf_dc, br);
    var diff: i32 = 0;
    if (cat != 0) {
        const bits = try br.readBits(@intCast(cat));
        if (bits & (@as(u32, 1) << @as(u5, @intCast(cat - 1))) != 0) {
            diff = @intCast(bits);
        } else {
            diff = @as(i32, @intCast(bits)) - ((@as(i32, 1) << @intCast(cat)) - 1);
        }
    }
    comp.pred_dc += diff;
    coef[0] = @intCast(comp.pred_dc);

    // AC: RLE with EOB / ZRL symbols.
    var k: u8 = 1;
    while (k <= 63) {
        const sym = try huffmanDecode(huf_ac, br);
        const r = sym >> 4;
        const s = sym & 15;
        if (s == 0) {
            if (r == 15) {
                k += 16; // ZRL
            } else {
                break; // EOB
            }
        } else {
            k += r;
            if (k > 63) return error.BadACRun;
            const bits = try br.readBits(@intCast(s));
            var val: i32 = 0;
            if (bits & (@as(u32, 1) << @as(u5, @intCast(s - 1))) != 0) {
                val = @intCast(bits);
            } else {
                val = @as(i32, @intCast(bits)) - ((@as(i32, 1) << @intCast(s)) - 1);
            }
            coef[k] = @intCast(val);
            k += 1;
        }
    }
}

// ── Segment skipping / parsing ──────────────────────────────────────────────

fn skipSegment(data: []const u8, pos_in: usize) !usize {
    if (pos_in + 2 > data.len) return error.Truncated;
    const seg_len = std.mem.readInt(u16, data[pos_in..][0..2], .big);
    if (seg_len < 2) return error.InvalidSegment;
    const next = pos_in + seg_len;
    if (next > data.len) return error.Truncated;
    return next;
}

fn parseDqtTable(data: []const u8, pos_in: usize, end: usize) !void {
    // Quantization tables are not needed for coefficient extraction; only
    // validate bounds so the segment can be walked.
    var pos = pos_in;
    while (pos < end) {
        const pq = data[pos] >> 4;
        pos += 1;
        const size: usize = if (pq == 0) 64 else 128;
        if (pos + size > end) return error.InvalidQuantTable;
        pos += size;
    }
}

fn parseHuffTables(
    data: []const u8,
    pos_in: usize,
    end: usize,
    dc_huff: *[4]HuffTable,
    ac_huff: *[4]HuffTable,
) !void {
    var pos = pos_in;
    while (pos < end) {
        const tc = data[pos] >> 4; // 0 = DC, 1 = AC
        const id = data[pos] & 0x0F;
        pos += 1;
        if (id > 3) return error.InvalidHuffman;
        if (pos + 16 > end) return error.InvalidHuffman;

        var counts: [17]u32 = @splat(0);
        var total: u32 = 0;
        for (1..17) |b| {
            counts[b] = data[pos + b - 1];
            total += counts[b];
        }
        pos += 16;
        if (total > 256) return error.InvalidHuffman;
        if (pos + total > end) return error.InvalidHuffman;

        const table: *HuffTable = if (tc == 0) &dc_huff[id] else &ac_huff[id];
        table.num_symbols = @intCast(total);

        // Canonical code assignment.
        var code: i32 = 0;
        var k: u32 = 0;
        for (1..17) |b| {
            k += counts[b];
            if (counts[b] > 0) {
                table.min_code[b] = code;
                table.max_code[b] = code + @as(i32, @intCast(counts[b])) - 1;
                table.val_offset[b] = k - counts[b];
            } else {
                table.min_code[b] = -1;
                table.max_code[b] = -1;
                table.val_offset[b] = k;
            }
            code = (code + @as(i32, @intCast(counts[b]))) << 1;
        }
        for (0..total) |i| {
            table.symbols[i] = data[pos + i];
        }
        pos += total;
    }
}

// ── Scan decode ──────────────────────────────────────────────────────────────

const ScanOut = struct {
    carriers: []u8,
    blocks_x: u32,
    blocks_y: u32,
    /// Byte position right after the entropy-coded scan data (points at the
    /// terminating marker's 0xFF).
    end_pos: usize,
};

fn decodeScan(
    allocator: std.mem.Allocator,
    data: []const u8,
    pos0: usize,
    frame: *Frame,
    dc_huff: *const [4]HuffTable,
    ac_huff: *const [4]HuffTable,
    restart_interval: u16,
) !ScanOut {
    // Luminance = first frame component.
    const comp0 = frame.comps[0];
    const mcus_x = @divTrunc(@as(u32, frame.width) + @as(u32, 8 * frame.hmax) - 1, 8 * frame.hmax);
    const mcus_y = @divTrunc(@as(u32, frame.height) + @as(u32, 8 * frame.vmax) - 1, 8 * frame.vmax);
    const blocks_x = mcus_x * comp0.h;
    const blocks_y = mcus_y * comp0.v;

    const total_blocks = @as(u64, blocks_x) * blocks_y;
    if (total_blocks > MAX_BLOCKS) return error.ImageTooLarge;

    const carriers = try allocator.alloc(u8, total_blocks * BPP);
    errdefer allocator.free(carriers);
    @memset(carriers, 0);

    var br = BitReader{ .data = data, .pos = pos0 };
    var coef: [64]i16 = undefined;

    var mcu_idx: usize = 0;
    for (0..mcus_y) |mcu_y| {
        for (0..mcus_x) |mcu_x| {
            if (restart_interval > 0 and mcu_idx > 0 and mcu_idx % restart_interval == 0) {
                br.resetByteAligned();
                const expected = M_RST0 + @as(u8, @intCast((mcu_idx / restart_interval) % 8));
                if (br.pos + 1 >= data.len) return error.Truncated;
                if (data[br.pos] != 0xFF or data[br.pos + 1] != expected) return error.RestartMismatch;
                br.pos += 2;
                for (frame.comps[0..frame.ncomp]) |*c| c.pred_dc = 0;
            }

            for (frame.comps[0..frame.ncomp], 0..) |*comp, ci| {
                const huf_dc = &dc_huff[comp.dc_tbl];
                const huf_ac = &ac_huff[comp.ac_tbl];
                for (0..comp.v) |vv| {
                    for (0..comp.h) |hh| {
                        try decodeBlock(huf_dc, huf_ac, comp, &br, &coef);
                        if (ci == 0) {
                            const bx = mcu_x * comp.h + hh;
                            const by = mcu_y * comp.v + vv;
                            if (bx >= blocks_x or by >= blocks_y) return error.BadGeometry;
                            const block_off = (by * blocks_x + bx) * BPP;
                            for (AC_BAND_LO..AC_BAND_HI + 1) |z| {
                                const mag = @abs(coef[z]);
                                const v: u8 = if (mag >= 2 and mag <= 254) @intCast(mag) else 0;
                                carriers[block_off + (z - AC_BAND_LO)] = v;
                            }
                        }
                    }
                }
            }
            mcu_idx += 1;
        }
    }

    return .{
        .carriers = carriers,
        .blocks_x = blocks_x,
        .blocks_y = blocks_y,
        .end_pos = br.pos,
    };
}

// ── Public decoder ───────────────────────────────────────────────────────────

/// Decode a baseline JPEG into stego carrier bytes.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !root.Decoded {
    if (data.len < 4) return error.NotJpeg;
    if (data[0] != 0xFF or data[1] != M_SOI) return error.NotJpeg;

    var frame = Frame{};
    var dc_huff: [4]HuffTable = .{ .{}, .{}, .{}, .{} };
    var ac_huff: [4]HuffTable = .{ .{}, .{}, .{}, .{} };
    var restart_interval: u16 = 0;
    var app1_payload: ?[]const u8 = null;
    var saw_sof = false;
    var decoded: ?ScanOut = null;

    var pos: usize = 2;
    while (true) {
        if (pos + 1 >= data.len) return error.Truncated;
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos < data.len and data[pos] == 0xFF) pos += 1; // fill bytes
        if (pos >= data.len) return error.Truncated;
        const marker = data[pos];
        pos += 1;

        switch (marker) {
            M_SOI => continue,
            M_EOI => break,
            M_SOF0 => {
                if (pos + 2 > data.len) return error.Truncated;
                const seg_len = std.mem.readInt(u16, data[pos..][0..2], .big);
                const seg_data = data[pos + 2 .. pos + seg_len];
                pos = try skipSegment(data, pos);

                if (seg_data.len < 6) return error.InvalidSOF;
                frame.precision = seg_data[0];
                frame.height = std.mem.readInt(u16, seg_data[1..3], .big);
                frame.width = std.mem.readInt(u16, seg_data[3..5], .big);
                frame.ncomp = seg_data[5];
                if (frame.precision != 8) return error.UnsupportedBitDepth;
                if (frame.ncomp != 1 and frame.ncomp != 3) return error.UnsupportedJpeg; // reject CMYK etc.
                if (seg_data.len < 6 + 3 * frame.ncomp) return error.InvalidSOF;
                if (frame.width == 0 or frame.height == 0) return error.InvalidSOF;

                var hmax: u8 = 0;
                var vmax: u8 = 0;
                for (0..frame.ncomp) |i| {
                    const c = &frame.comps[i];
                    c.id = seg_data[6 + 3 * i];
                    c.h = seg_data[6 + 3 * i + 1] >> 4;
                    c.v = seg_data[6 + 3 * i + 1] & 0x0F;
                    c.tq = seg_data[6 + 3 * i + 2];
                    if (c.h == 0 or c.h > 4 or c.v == 0 or c.v > 4) return error.InvalidSampling;
                    hmax = @max(hmax, c.h);
                    vmax = @max(vmax, c.v);
                }
                frame.hmax = hmax;
                frame.vmax = vmax;
                saw_sof = true;
            },
            M_DQT => {
                const end = try skipSegment(data, pos);
                try parseDqtTable(data, pos + 2, end);
                pos = end;
            },
            M_DHT => {
                const end = try skipSegment(data, pos);
                try parseHuffTables(data, pos + 2, end, &dc_huff, &ac_huff);
                pos = end;
            },
            M_DRI => {
                const end = try skipSegment(data, pos);
                if (end - pos < 4) return error.Truncated;
                restart_interval = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
                pos = end;
            },
            M_COM => {
                pos = try skipSegment(data, pos);
            },
            M_APP1 => {
                const end = try skipSegment(data, pos);
                if (end > pos + 2 and app1_payload == null) {
                    const payload = data[pos + 2 .. end];
                    if (std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
                        app1_payload = payload;
                    }
                }
                pos = end;
            },
            M_SOS => {
                if (!saw_sof) return error.MissingSOF;
                const end = try skipSegment(data, pos);
                const seg_data = data[pos + 2 .. end];
                if (seg_data.len < 4) return error.InvalidSOS;
                const nsc = seg_data[0];
                if (nsc != frame.ncomp) return error.UnsupportedScan;
                if (seg_data.len < 1 + 2 * nsc + 3) return error.InvalidSOS;

                for (0..nsc) |i| {
                    const cid = seg_data[1 + 2 * i];
                    const tbls = seg_data[1 + 2 * i + 1];
                    // Map scan component to frame component.
                    var found = false;
                    for (0..frame.ncomp) |j| {
                        if (frame.comps[j].id == cid) {
                            frame.comps[j].dc_tbl = tbls >> 4;
                            frame.comps[j].ac_tbl = tbls & 0x0F;
                            if (frame.comps[j].dc_tbl > 3 or frame.comps[j].ac_tbl > 3) return error.InvalidSOS;
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.InvalidSOS;
                }
                const ss = seg_data[1 + 2 * nsc];
                const se = seg_data[1 + 2 * nsc + 1];
                const ah_al = seg_data[1 + 2 * nsc + 2];
                if (ss != 0 or se != 63 or ah_al != 0) return error.UnsupportedJpeg; // progressive

                // Validate the Huffman tables referenced by the scan exist.
                for (0..frame.ncomp) |j| {
                    if (frame.comps[j].dc_tbl >= 4 or frame.comps[j].ac_tbl >= 4) return error.InvalidSOS;
                    if (dc_huff[frame.comps[j].dc_tbl].num_symbols == 0) return error.MissingHuffman;
                    if (ac_huff[frame.comps[j].ac_tbl].num_symbols == 0) return error.MissingHuffman;
                }

                decoded = try decodeScan(allocator, data, end, &frame, &dc_huff, &ac_huff, restart_interval);
                pos = decoded.?.end_pos; // continue at the marker after the scan
            },
            M_TEM => return error.UnsupportedJpeg,
            M_RST0...M_RST7 => return error.InvalidMarker,
            else => {
                if (marker >= 0xD0 and marker <= 0xD9) return error.InvalidMarker;
                // SOF1..SOF15 except SOF0, APPn, COM handled above, etc.
                if (marker >= M_SOF0 and marker <= 0xCF and marker != M_SOF0 and marker != M_DHT) {
                    return error.UnsupportedJpeg;
                }
                pos = try skipSegment(data, pos);
            },
        }
    }

    const out = decoded orelse return error.MissingSOS;

    var salt_material: [root.SALT_MATERIAL_MAX]u8 = @splat(0);
    var salt_material_len: usize = 0;
    if (app1_payload) |p| {
        // SOF frame dimensions (pixels), matching the Python side's SOF parse.
        if (exif.buildMaterial(p, frame.width, frame.height, &salt_material)) |len| {
            salt_material_len = len;
        }
    }
    return .{
        .carriers = out.carriers,
        .width = out.blocks_x,
        .height = out.blocks_y,
        .bpp = BPP,
        .salt_material = salt_material,
        .salt_material_len = salt_material_len,
    };
}

/// Minimal baseline JPEG encoder for round-trip tests.
///
/// Takes the carrier array produced by `decode` (or hand-built) and writes a
/// grayscale baseline JPEG whose Y quantized coefficients reproduce those
/// carriers exactly: identity quantization tables and fixed Annex K
/// luminance Huffman tables.  `carriers` must hold
/// `blocks_x * blocks_y * BPP` magnitude bytes.
pub fn encodeForTest(
    carriers: []const u8,
    blocks_x: u32,
    blocks_y: u32,
    allocator: std.mem.Allocator,
) ![]u8 {
    const total_blocks = @as(usize, blocks_x) * blocks_y;
    if (carriers.len < total_blocks * BPP) return error.CarrierTooShort;
    if (blocks_x == 0 or blocks_y == 0) return error.InvalidDimensions;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_SOI });

    // DQT: identity table 0 (all ones) so quantized == stored.
    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_DQT, 0x00, 0x43, 0x00 });
    for (0..64) |_| try out.append(allocator, 1);

    // SOF0: 8-bit, grayscale.
    const width: u16 = @intCast(blocks_x * 8);
    const height: u16 = @intCast(blocks_y * 8);
    try out.appendSlice(allocator, &[_]u8{
        0xFF, M_SOF0,
        0x00,              0x0B, // length
        8,                 @truncate(height >> 8),
        @truncate(height), @truncate(width >> 8),
        @truncate(width), 1, // ncomp
        1, 0x11, // id=1, sampling H1V1
        0, // quant table 0
    });

    // DHT: luminance DC table 0.
    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_DHT, 0x00, 0x1F, 0x00 });
    try out.appendSlice(allocator, &STD_DC_LUMA_COUNTS);
    try out.appendSlice(allocator, &STD_DC_LUMA_SYMS);

    // DHT: luminance AC table 0.
    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_DHT, 0x00, 0xB5, 0x10 });
    try out.appendSlice(allocator, &STD_AC_LUMA_COUNTS);
    try out.appendSlice(allocator, &STD_AC_LUMA_SYMS);

    // SOS: baseline, single component.
    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_SOS, 0x00, 0x08, 1, 1, 0x00, 0, 63, 0 });

    // Entropy-coded data.
    var w = BitWriter{ .out = &out, .allocator = allocator };
    const dc_codes = comptime canonicalCodes(&STD_DC_LUMA_COUNTS, &STD_DC_LUMA_SYMS);
    const ac_codes = comptime canonicalCodes(&STD_AC_LUMA_COUNTS, &STD_AC_LUMA_SYMS);
    var prev_dc: i32 = 0;
    var coef: [64]i16 = @splat(0);
    for (0..total_blocks) |bi| {
        @memset(&coef, 0);
        for (AC_BAND_LO..AC_BAND_HI + 1) |z| {
            coef[z] = carriers[bi * BPP + (z - AC_BAND_LO)];
        }
        try encodeBlock(&coef, &prev_dc, &w, &dc_codes, &ac_codes);
    }
    try w.finish();

    try out.appendSlice(allocator, &[_]u8{ 0xFF, M_EOI });
    return out.toOwnedSlice(allocator);
}

// ── Test encoder internals ───────────────────────────────────────────────────

/// Annex K.3.1 luminance DC Huffman table: code counts per length 1..16.
const STD_DC_LUMA_COUNTS = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
/// Annex K.3.1 luminance DC symbols (categories 0..11).
const STD_DC_LUMA_SYMS = [12]u8{
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B,
};

/// Annex K.3.3.1 luminance AC Huffman table: code counts per length 1..16.
const STD_AC_LUMA_COUNTS = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D };
/// Annex K.3.3.1 luminance AC symbols.
const STD_AC_LUMA_SYMS = [162]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6A, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
    0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5,
    0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
    0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8,
    0xF9, 0xFA,
};

const CodeEntry = struct { code: u16, len: u8 };

fn canonicalCodes(comptime counts: *const [16]u8, comptime syms: []const u8) [256]CodeEntry {
    var out: [256]CodeEntry = @splat(.{ .code = 0, .len = 0 });
    var code: u32 = 0;
    var k: usize = 0;
    for (1..17) |b| {
        for (0..counts[b - 1]) |_| {
            out[syms[k]] = CodeEntry{ .code = @truncate(code), .len = @intCast(b) };
            k += 1;
            code += 1;
        }
        code <<= 1;
    }
    return out;
}

const BitWriter = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bit_buf: u32 = 0,
    bit_cnt: u5 = 0,

    fn putByte(self: *BitWriter, b: u8) !void {
        try self.out.append(self.allocator, b);
        if (b == 0xFF) try self.out.append(self.allocator, 0); // byte stuffing
    }

    fn writeBits(self: *BitWriter, code: u32, n: u8) !void {
        self.bit_buf = (self.bit_buf << @intCast(n)) | code;
        self.bit_cnt +%= @intCast(n);
        while (self.bit_cnt >= 8) {
            self.bit_cnt -%= 8;
            const byte: u8 = @truncate(self.bit_buf >> self.bit_cnt);
            self.bit_buf &= (@as(u32, 1) << self.bit_cnt) - 1;
            try self.putByte(byte);
        }
    }

    fn finish(self: *BitWriter) !void {
        if (self.bit_cnt > 0) {
            const pad: u32 = (@as(u32, 1) << @intCast(8 - self.bit_cnt)) - 1;
            self.bit_buf = (self.bit_buf << @intCast(8 - self.bit_cnt)) | pad;
            try self.putByte(@truncate(self.bit_buf));
            self.bit_buf = 0;
            self.bit_cnt = 0;
        }
    }
};

fn encodeDc(diff: i32, w: *BitWriter, dc_codes: *const [256]CodeEntry) !void {
    if (diff == 0) {
        try w.writeBits(dc_codes[0].code, dc_codes[0].len);
        return;
    }
    const mag = @abs(diff);
    var cat: u8 = 0;
    var m = mag;
    while (m > 0) : (cat += 1) m >>= 1;
    try w.writeBits(dc_codes[cat].code, dc_codes[cat].len);
    if (diff > 0) {
        try w.writeBits(@intCast(diff), cat);
    } else {
        try w.writeBits(@as(u32, @intCast(diff - 1 + (@as(i32, 1) << @intCast(cat)))), cat);
    }
}

fn encodeAcSym(w: *BitWriter, ac_codes: *const [256]CodeEntry, sym: u8, val: i32) !void {
    try w.writeBits(ac_codes[sym].code, ac_codes[sym].len);
    if (val > 0) {
        try w.writeBits(@intCast(val), sym & 15);
    } else {
        const cat = sym & 15;
        try w.writeBits(@as(u32, @intCast(val - 1 + (@as(i32, 1) << @intCast(cat)))), cat);
    }
}

fn encodeBlock(
    coef: *const [64]i16,
    prev_dc: *i32,
    w: *BitWriter,
    dc_codes: *const [256]CodeEntry,
    ac_codes: *const [256]CodeEntry,
) !void {
    const diff = coef[0] - prev_dc.*;
    prev_dc.* = coef[0];
    try encodeDc(diff, w, dc_codes);

    var run: u8 = 0;
    var any_nonzero = false;
    for (1..64) |k| {
        if (coef[k] == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) {
            try w.writeBits(ac_codes[0xF0].code, ac_codes[0xF0].len);
            run -= 16;
        }
        const mag = @abs(coef[k]);
        var cat: u8 = 0;
        var m = mag;
        while (m > 0) : (cat += 1) m >>= 1;
        try encodeAcSym(w, ac_codes, (run << 4) | cat, coef[k]);
        run = 0;
        any_nonzero = true;
    }
    if (run > 0 or !any_nonzero) {
        try w.writeBits(ac_codes[0x00].code, ac_codes[0x00].len); // EOB
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "decode: wrong magic returns NotJpeg" {
    const allocator = std.testing.allocator;
    const bad = try allocator.alloc(u8, 8);
    defer allocator.free(bad);
    @memset(bad, 0);
    try std.testing.expectError(error.NotJpeg, decode(allocator, bad));
}

test "decode: progressive SOF2 returns UnsupportedJpeg" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xFF, M_SOI, 0xFF, 0xC2 };
    try std.testing.expectError(error.UnsupportedJpeg, decode(allocator, &data));
}

test "encodeForTest / decode round-trip" {
    const allocator = std.testing.allocator;
    const blocks_x: u32 = 8;
    const blocks_y: u32 = 6;
    const total_blocks = blocks_x * blocks_y;
    const n = total_blocks * BPP;

    const carriers = try allocator.alloc(u8, n);
    defer allocator.free(carriers);
    for (carriers, 0..) |*p, i| {
        p.* = if (i % 5 == 0) 0 else @as(u8, @intCast((i * 7 % 253) + 2));
    }

    const jpg = try encodeForTest(carriers, blocks_x, blocks_y, allocator);
    defer allocator.free(jpg);

    const decoded = try decode(allocator, jpg);
    defer allocator.free(decoded.carriers);

    try std.testing.expectEqual(blocks_x, decoded.width);
    try std.testing.expectEqual(blocks_y, decoded.height);
    try std.testing.expectEqual(BPP, decoded.bpp);
    try std.testing.expectEqualSlices(u8, carriers, decoded.carriers);
    // The test encoder writes no EXIF: no salt material may be recovered.
    try std.testing.expectEqual(@as(usize, 0), decoded.salt_material_len);
}

test "encodeForTest rejects short carrier" {
    const allocator = std.testing.allocator;
    const tiny = try allocator.alloc(u8, 4);
    defer allocator.free(tiny);
    try std.testing.expectError(error.CarrierTooShort, encodeForTest(tiny, 8, 8, allocator));
}

// ── libjpeg oracle tests ─────────────────────────────────────────────────────

const oracle_color = @import("oracle_color.zig");
const oracle_gray = @import("oracle_gray.zig");

const oracle_color_jpg = @embedFile("fixtures/oracle_color.jpg");
const oracle_gray_jpg = @embedFile("fixtures/oracle_gray.jpg");

fn expectOracleMatch(allocator: std.mem.Allocator, data: []const u8, oracle: anytype) !void {
    const decoded = try decode(allocator, data);
    defer allocator.free(decoded.carriers);

    try std.testing.expectEqual(oracle.BLOCKS_X, decoded.width);
    try std.testing.expectEqual(oracle.BLOCKS_Y, decoded.height);
    try std.testing.expectEqual(BPP, decoded.bpp);

    const expected_len = oracle.BLOCKS_X * oracle.BLOCKS_Y * BPP;
    try std.testing.expectEqual(@as(usize, expected_len), decoded.carriers.len);
    try std.testing.expectEqualSlices(u8, &oracle.carriers, decoded.carriers);

    // Salt material recovered from the injected EXIF APP1 segment.
    try std.testing.expect(decoded.salt_material_len > 0);
    const hex_chars = "0123456789abcdef";
    var mat_hex_buf: [root.SALT_MATERIAL_MAX * 2]u8 = undefined;
    for (decoded.salt_material[0..decoded.salt_material_len], 0..) |byte, i| {
        mat_hex_buf[i * 2 + 0] = hex_chars[byte >> 4];
        mat_hex_buf[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    try std.testing.expectEqualStrings(
        oracle.MATERIAL_HEX,
        mat_hex_buf[0 .. decoded.salt_material_len * 2],
    );
}

test "decode matches libjpeg oracle (color 4:2:0)" {
    try expectOracleMatch(std.testing.allocator, oracle_color_jpg, oracle_color);
}

test "decode matches libjpeg oracle (grayscale)" {
    try expectOracleMatch(std.testing.allocator, oracle_gray_jpg, oracle_gray);
}
