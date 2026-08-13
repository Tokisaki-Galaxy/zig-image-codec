//! PNG decoder -> carrier bytes (raw scanline pixel buffer).
//!
//! Supports 8-bit PNGs of color types 0 (grayscale), 2 (RGB), 4 (grayscale +
//! alpha) and 6 (RGBA), reversing all five filter types.
//!
//! The carrier for the stego layer is the raw pixel byte buffer; `width` /
//! `height` are the pixel grid dimensions and `bpp` the bytes per pixel.
//! An anti-decompression-bomb cap rejects images whose raw pixel data would
//! exceed `MAX_PIXEL_BYTES`.  The dead-drop salt material is JPEG-EXIF-only;
//! PNG decode never recovers any (`salt_material_len` stays 0).

const std = @import("std");
const root = @import("root.zig");

const PNG_MAGIC = "\x89PNG\r\n\x1a\n";

/// Anti-decompression-bomb: reject any image whose raw pixel data would
/// exceed 20 MiB.
pub const MAX_PIXEL_BYTES: u64 = 20 * 1024 * 1024;

/// Paeth predictor for PNG filter type 4.
fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia: i16 = a;
    const ib: i16 = b;
    const ic: i16 = c;
    const p = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Decode a PNG into stego carrier bytes.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !root.Decoded {
    if (data.len < 8) return error.NotPng;
    if (!std.mem.eql(u8, data[0..8], PNG_MAGIC)) return error.NotPng;

    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var found_ihdr = false;
    var idat_buf = std.ArrayList(u8).empty;
    defer idat_buf.deinit(allocator);

    while (pos + 8 <= data.len) {
        const chunk_len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const chunk_type = data[pos + 4 .. pos + 8];
        const chunk_data = data[pos + 8 .. pos + 8 + chunk_len];
        if (pos + 8 + chunk_len + 4 > data.len) return error.TruncatedPng;

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (chunk_data.len < 13) return error.InvalidPng;
            width = std.mem.readInt(u32, chunk_data[0..4], .big);
            height = std.mem.readInt(u32, chunk_data[4..8], .big);
            bit_depth = chunk_data[8];
            color_type = chunk_data[9];
            found_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            try idat_buf.appendSlice(allocator, chunk_data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        }

        pos += 8 + chunk_len + 4; // length + type + data + crc
    }

    if (!found_ihdr) return error.MissingIHDR;
    if (idat_buf.items.len == 0) return error.MissingIDAT;
    if (bit_depth != 8) return error.UnsupportedBitDepth;

    const bpp: u8 = switch (color_type) {
        0 => 1, // Grayscale
        2 => 3, // RGB
        4 => 2, // Grayscale + Alpha
        6 => 4, // RGBA
        else => return error.UnsupportedColorType,
    };

    // Anti-decompression-bomb: reject oversized images upfront.
    const total_raw = @as(u64, width) * @as(u64, height) * bpp;
    if (total_raw > MAX_PIXEL_BYTES) return error.ImageTooLarge;

    // Decompress zlib-wrapped deflate.
    var input_reader: std.Io.Reader = .fixed(idat_buf.items);
    var decomp_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer decomp_out.deinit();
    {
        var inflate = std.compress.flate.Decompress.init(&input_reader, .zlib, &.{});
        _ = try inflate.reader.streamRemaining(&decomp_out.writer);
    }
    const decompressed = try decomp_out.toOwnedSlice();
    errdefer allocator.free(decompressed);

    // Reverse per-scanline filters.
    const row_bytes: usize = width * bpp;
    const expected_raw = (1 + row_bytes) * height; // 1 filter byte per row

    if (decompressed.len > expected_raw * 2) {
        allocator.free(decompressed);
        return error.DecompressBomb;
    }
    if (decompressed.len < expected_raw) return error.TruncatedDecompressed;

    var pixels = try allocator.alloc(u8, width * height * bpp);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);

    var src: usize = 0;
    var prev_row: []const u8 = &.{};

    for (0..height) |y| {
        const filter = decompressed[src];
        src += 1;
        const row_data = decompressed[src..][0..row_bytes];
        src += row_bytes;

        const cur_row = pixels[y * row_bytes .. (y + 1) * row_bytes];

        for (0..row_bytes) |x| {
            const raw = row_data[x];
            const left = if (x >= bpp) cur_row[x - bpp] else @as(u8, 0);
            const up = if (y > 0) prev_row[x] else @as(u8, 0);
            const upper_left = if (x >= bpp and y > 0) prev_row[x - bpp] else @as(u8, 0);

            cur_row[x] = switch (filter) {
                0 => raw, // None
                1 => raw +% left, // Sub
                2 => raw +% up, // Up
                3 => raw +% @as(u8, @truncate((@as(u16, left) + @as(u16, up)) / 2)), // Average
                4 => raw +% paethPredictor(left, up, upper_left), // Paeth
                else => return error.UnknownFilter,
            };
        }

        prev_row = cur_row;
    }

    allocator.free(decompressed);
    return .{
        .carriers = pixels,
        .width = width,
        .height = height,
        .bpp = bpp,
    };
}

test "paethPredictor: basic cases" {
    try std.testing.expectEqual(@as(u8, 20), paethPredictor(10, 20, 5));
    try std.testing.expectEqual(@as(u8, 20), paethPredictor(5, 20, 10));
    try std.testing.expectEqual(@as(u8, 100), paethPredictor(100, 50, 15));
}

test "paethPredictor: edge values" {
    try std.testing.expectEqual(@as(u8, 42), paethPredictor(42, 42, 42));
    try std.testing.expectEqual(@as(u8, 3), paethPredictor(0, 5, 3));
}

test "decode: wrong magic returns NotPng" {
    const allocator = std.testing.allocator;
    const bad = try allocator.alloc(u8, 16);
    defer allocator.free(bad);
    @memset(bad, 0);
    try std.testing.expectError(error.NotPng, decode(allocator, bad));
}

/// Build a minimal valid PNG from raw pixel data (test helper).
/// Uses deflate stored blocks (no compression) to avoid zlib compressor
/// complexity.  Mirrors the operator encoder's output shape.
pub fn encodeForTest(
    pixels: []const u8,
    width: u32,
    height: u32,
    bpp: u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const row_bytes = width * bpp;
    const scanline_bytes = 1 + row_bytes;
    const raw_len = scanline_bytes * height;

    // Build scanline data with filter byte 0 (None) per row.
    var scanlines = try allocator.alloc(u8, raw_len);
    defer allocator.free(scanlines);
    for (0..height) |y| {
        scanlines[y * scanline_bytes] = 0;
        @memcpy(scanlines[y * scanline_bytes + 1 ..][0..row_bytes], pixels[y * row_bytes .. (y + 1) * row_bytes]);
    }

    // Zlib wrapper with deflate stored blocks.
    var zlib_data = std.ArrayList(u8).empty;
    defer zlib_data.deinit(allocator);

    // Zlib header: CMF=0x78 (deflate, 32K window), FLG=0x01.
    try zlib_data.append(allocator, 0x78);
    try zlib_data.append(allocator, 0x01);

    // Single deflate stored block (raw_len < 65535 guaranteed for test data).
    const is_final: u8 = 1;
    try zlib_data.append(allocator, is_final); // BFINAL=1, BTYPE=00
    try zlib_data.appendSlice(allocator, &[_]u8{
        @truncate(@as(u16, @intCast(raw_len))),
        @truncate(@as(u16, @intCast(raw_len >> 8))),
    });
    try zlib_data.appendSlice(allocator, &[_]u8{
        @truncate(~@as(u16, @intCast(raw_len))),
        @truncate(~@as(u16, @intCast(raw_len >> 8))),
    });
    try zlib_data.appendSlice(allocator, scanlines);

    // Adler32 checksum of scanlines.
    const adler = std.hash.Adler32.hash(scanlines);
    try zlib_data.appendSlice(allocator, &[_]u8{
        @truncate(@as(u32, adler >> 24)),
        @truncate(@as(u32, adler >> 16)),
        @truncate(@as(u32, adler >> 8)),
        @truncate(adler),
    });

    const idat_data = zlib_data.items;

    // Build PNG.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "\x89PNG\r\n\x1a\n");

    // IHDR chunk.
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = switch (bpp) {
        1 => 0, // Grayscale
        2 => 4, // Grayscale + Alpha
        3 => 2, // RGB
        4 => 6, // RGBA
        else => return error.UnsupportedColorType,
    };
    ihdr[10] = 0; // compression (deflate)
    ihdr[11] = 0; // filter (adaptive)
    ihdr[12] = 0; // interlace (none)

    var ihdr_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &ihdr_len_buf, 13, .big);
    try out.appendSlice(allocator, &ihdr_len_buf);
    try out.appendSlice(allocator, "IHDR");
    try out.appendSlice(allocator, &ihdr);

    var ihdr_crc = std.hash.crc.Crc32.init();
    ihdr_crc.update("IHDR"[0..]);
    ihdr_crc.update(&ihdr);
    const ihdr_crc_val = ihdr_crc.final();
    var ihdr_crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &ihdr_crc_buf, ihdr_crc_val, .big);
    try out.appendSlice(allocator, &ihdr_crc_buf);

    // IDAT chunk.
    var idat_len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &idat_len_buf, @intCast(idat_data.len), .big);
    try out.appendSlice(allocator, &idat_len_buf);
    try out.appendSlice(allocator, "IDAT");
    try out.appendSlice(allocator, idat_data);

    var idat_crc = std.hash.crc.Crc32.init();
    idat_crc.update("IDAT"[0..]);
    idat_crc.update(idat_data);
    const idat_crc_val = idat_crc.final();
    var idat_crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &idat_crc_buf, idat_crc_val, .big);
    try out.appendSlice(allocator, &idat_crc_buf);

    // IEND chunk.
    var iend_crc = std.hash.crc.Crc32.init();
    iend_crc.update("IEND"[0..]);
    const iend_crc_val = iend_crc.final();
    var iend_crc_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &iend_crc_buf, iend_crc_val, .big);

    try out.appendSlice(allocator, &[_]u8{ 0, 0, 0, 0 }); // length = 0
    try out.appendSlice(allocator, "IEND");
    try out.appendSlice(allocator, &iend_crc_buf);

    return out.toOwnedSlice(allocator);
}

test "decode round-trip with encodeForTest" {
    const allocator = std.testing.allocator;
    const width: u32 = 64;
    const height: u32 = 32;
    const bpp: u8 = 4;
    const pixel_count = width * height * bpp;

    const pixels = try allocator.alloc(u8, pixel_count);
    defer allocator.free(pixels);
    for (pixels, 0..) |*p, i| p.* = @intCast((i * 7) % 256);

    const png_data = try encodeForTest(pixels, width, height, bpp, allocator);
    defer allocator.free(png_data);

    const decoded = try decode(allocator, png_data);
    defer allocator.free(decoded.carriers);

    try std.testing.expectEqual(width, decoded.width);
    try std.testing.expectEqual(height, decoded.height);
    try std.testing.expectEqual(bpp, decoded.bpp);
    try std.testing.expectEqualSlices(u8, pixels, decoded.carriers);
    try std.testing.expectEqual(@as(usize, 0), decoded.salt_material_len);
}
