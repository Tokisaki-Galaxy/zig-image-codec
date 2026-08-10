//! JPEG decoder → carrier bytes (Y quantized AC coefficient magnitudes).
//! Baseline DCT (SOF0) entropy decode only — stops before IDCT / color
//! conversion. Implemented from ITU-T T.81 (step 4 fills this in).

const std = @import("std");
const root = @import("root.zig");

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !root.Decoded {
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}
