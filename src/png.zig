//! PNG decoder → carrier bytes (raw scanline pixels).
//! Migrated from zafkiel `src/client_deaddrop.zig` (step 3 fills this in).

const std = @import("std");
const root = @import("root.zig");

pub fn decode(allocator: std.mem.Allocator, data: []const u8) !root.Decoded {
    _ = allocator;
    _ = data;
    return error.NotImplemented;
}
