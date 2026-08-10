//! zig-image-codec — PNG & JPEG decoders exposing stego carrier bytes.
//!
//! Pure `std`, Zig 0.16. The client (zafkiel) imports this module and calls
//! `decodeJpeg` only; `decodePng` is provided for format completeness and is
//! never linked into the client (Zig lazy compilation).
//!
//! ## Carrier contract
//!
//! Both decoders produce a `Decoded` whose `carriers` byte array feeds a
//! PRNG-scatter / matrix-embedding stego layer unchanged:
//!
//! - PNG  → raw scanline pixel bytes (`width`×`height` grid, `bpp` 1..4).
//! - JPEG → luminance (Y) quantized AC coefficient magnitudes, zig-zag band
//!   [1..32], `|coef| ∈ [2, 254]`, block-major over the 8×8 DCT grid
//!   (`width`=blocks_x, `height`=blocks_y, `bpp`=31).
//!
//! See `docs/stego.md` for the full stego-facing specification.

const std = @import("std");

pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");

const SALT_TEXT_KEY = "Software";
const SALT_TEXT_MARKER = "sid=";
pub const SALT_BYTES: usize = 16;

/// Recover the 16-byte KDF salt from a metadata payload of the form
/// `Software\0<...>; sid=<base64url>` (PNG tEXt / JPEG COM).
pub fn parseSaltText(chunk_data: []const u8) !?[SALT_BYTES]u8 {
    const sep = std.mem.indexOfScalar(u8, chunk_data, 0) orelse return null;
    const key = chunk_data[0..sep];
    if (!std.mem.eql(u8, key, SALT_TEXT_KEY) and !std.mem.eql(u8, key, "Description")) {
        return null;
    }

    const value = chunk_data[sep + 1 ..];
    const marker_pos = std.mem.indexOf(u8, value, SALT_TEXT_MARKER) orelse return null;
    var sid = value[marker_pos + SALT_TEXT_MARKER.len ..];
    if (std.mem.indexOfScalar(u8, sid, ';')) |end| sid = sid[0..end];
    sid = std.mem.trim(u8, sid, " \t\r\n");
    if (sid.len == 0) return error.InvalidSaltMetadata;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(sid) catch return error.InvalidSaltMetadata;
    if (decoded_len != SALT_BYTES) return error.InvalidSaltMetadata;

    var salt: [SALT_BYTES]u8 = undefined;
    decoder.decode(&salt, sid) catch return error.InvalidSaltMetadata;
    return salt;
}

/// Uniform decoded output consumed by the stego layer.
pub const Decoded = struct {
    /// Carrier byte array. The caller owns this memory (must free).
    carriers: []u8,
    /// PNG: pixel grid width. JPEG: DCT blocks across.
    width: u32,
    /// PNG: pixel grid height. JPEG: DCT blocks down.
    height: u32,
    /// PNG: bytes per pixel (1..4). JPEG: AC coefficients per block (31).
    bpp: u8,
    /// Optional 16-byte KDF salt recovered from metadata (PNG tEXt / JPEG COM).
    salt: ?[16]u8,
};

/// Decode a PNG into carrier bytes. Fails with `error.NotPng` if the magic
/// signature is absent.
pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    return png.decode(allocator, data);
}

/// Decode a baseline JPEG into quantized-coefficient carrier bytes. Fails
/// with `error.NotJpeg` if the SOI marker is absent.
pub fn decodeJpeg(allocator: std.mem.Allocator, data: []const u8) !Decoded {
    return jpeg.decode(allocator, data);
}

/// Minimal PNG encoder for round-trip tests (same shape as `decodePng`).
pub fn encodePngForTest(
    pixels: []const u8,
    width: u32,
    height: u32,
    bpp: u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    return png.encodeForTest(pixels, width, height, bpp, allocator);
}

/// Minimal baseline JPEG encoder for round-trip tests (same shape as
/// `decodeJpeg`).
pub fn encodeJpegForTest(
    y_coefficients: []const i16,
    blocks_x: u32,
    blocks_y: u32,
    allocator: std.mem.Allocator,
) ![]u8 {
    return jpeg.encodeForTest(y_coefficients, blocks_x, blocks_y, allocator);
}

test {
    std.testing.refAllDecls(@This());
    _ = png;
    _ = jpeg;
}
