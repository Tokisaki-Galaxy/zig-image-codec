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
//! The dead-drop salt is *derived* (client side) from `salt_material`, which
//! the JPEG decoder recovers from the cover's own EXIF (see `exif.zig`): the
//! cover image itself is never modified.  See `docs/stego.md` §8.

const std = @import("std");

pub const png = @import("png.zig");
pub const jpeg = @import("jpeg.zig");
pub const exif = @import("exif.zig");

/// Upper bound for the canonical salt material byte string
/// (`Make\0Model\0DateTimeOriginal\0SubsecTimeOriginal\0WxH`).
pub const SALT_MATERIAL_MAX: usize = 160;

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
    /// Canonical salt material (JPEG EXIF-derived; see `exif.zig`).
    /// `salt_material_len == 0` means no material was recoverable.
    salt_material: [SALT_MATERIAL_MAX]u8 = @splat(0),
    salt_material_len: usize = 0,
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
    carriers: []const u8,
    blocks_x: u32,
    blocks_y: u32,
    allocator: std.mem.Allocator,
) ![]u8 {
    return jpeg.encodeForTest(carriers, blocks_x, blocks_y, allocator);
}

test {
    std.testing.refAllDecls(@This());
    _ = png;
    _ = jpeg;
}
