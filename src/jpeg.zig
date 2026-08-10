//! JPEG decoder -> carrier bytes (Y quantized AC coefficient magnitudes).
//! Baseline DCT (SOF0) entropy decode only — stops before IDCT / color
//! conversion. Implemented from ITU-T T.81 (step 4 fills this in).

const std = @import("std");
const root = @import("root.zig");

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !root.Decoded {
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}

/// Minimal baseline JPEG encoder for round-trip tests.
pub fn encodeForTest(
    y_coefficients: []const i16,
    blocks_x: u32,
    blocks_y: u32,
    allocator: std.mem.Allocator,
) ![]u8 {
    _ = y_coefficients;
    _ = blocks_x;
    _ = blocks_y;
    _ = allocator;
    return error.NotImplemented;
}
