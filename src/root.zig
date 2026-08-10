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

test {
    std.testing.refAllDecls(@This());
    _ = png;
    _ = jpeg;
}
