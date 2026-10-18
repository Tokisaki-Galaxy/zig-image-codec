//! Minimal EXIF/APP1 parser: recovers the dead-drop salt material.
//!
//! The client never stores or writes anything into cover metadata — the salt
//! is *derived* from EXIF fields every real camera writes.  `buildMaterial`
//! walks the APP1 payload (TIFF, both byte orders) and emits the canonical
//! material byte string:
//!
//!     Make || '\0' || Model || '\0' || DateTimeOriginal || '\0'
//!         || SubsecTimeOriginal || '\0' || "<W>x<H>" (SOF dims, decimal)
//!
//! All four EXIF fields are REQUIRED: when any is missing the function
//! returns null and the caller fails closed (no salt -> MissingSalt).  The
//! Python mirror is `tools/exif_tool.py`; the cross-language layout is locked
//! by the e2e fixture (`tools/gen_e2e_fixture.py`).

const std = @import("std");

pub const MAX_IFD_ENTRIES: usize = 64;

const Entry = struct {
    tag: u16,
    ty: u16,
    count: u32,
    raw: u32,
    /// Position of the 4-byte value field within the TIFF slice.
    val_pos: usize,
};

fn readU16(data: []const u8, big: bool) u16 {
    return if (big) std.mem.readInt(u16, data[0..2], .big) else std.mem.readInt(u16, data[0..2], .little);
}

fn readU32(data: []const u8, big: bool) u32 {
    return if (big) std.mem.readInt(u32, data[0..4], .big) else std.mem.readInt(u32, data[0..4], .little);
}

fn parseIfd(tiff: []const u8, off: u32, big: bool, entries: []Entry) ?usize {
    const off_u: usize = off;
    if (off_u + 2 > tiff.len) return null;
    const count = readU16(tiff[off_u..][0..2], big);
    if (count > entries.len) return null;
    if (off_u + 2 + @as(usize, count) * 12 > tiff.len) return null;
    for (0..count) |i| {
        const e = tiff[off_u + 2 + i * 12 ..][0..12];
        entries[i] = .{
            .tag = readU16(e[0..2], big),
            .ty = readU16(e[2..4], big),
            .count = readU32(e[4..8], big),
            .raw = readU32(e[8..12], big),
            .val_pos = off_u + 2 + i * 12 + 8,
        };
    }
    return count;
}

/// Read an EXIF ASCII (type 2) value.  Trailing NULs and spaces are stripped,
/// mirroring `tools/exif_tool.py: _strip`.
fn asciiValue(tiff: []const u8, e: Entry) ?[]const u8 {
    if (e.ty != 2 or e.count == 0) return null;
    const n: usize = @intCast(e.count);
    const src: []const u8 = if (n <= 4)
        tiff[e.val_pos..][0..n]
    else blk: {
        const off: usize = e.raw;
        if (off + n > tiff.len) return null;
        break :blk tiff[off..][0..n];
    };
    var end = src.len;
    while (end > 0 and (src[end - 1] == 0 or src[end - 1] == ' ')) end -= 1;
    return src[0..end];
}

/// Recover the salt material from an APP1 payload ("Exif\0\0" + TIFF).
/// `width`/`height` are the SOF frame dimensions (pixels).  Returns the
/// material length written into `out`, or null when the payload is not a
/// valid EXIF or any required field is missing.
pub fn buildMaterial(payload: []const u8, width: u32, height: u32, out: []u8) ?usize {
    if (payload.len < 14) return null;
    if (!std.mem.eql(u8, payload[0..6], "Exif\x00\x00")) return null;
    const tiff = payload[6..];
    if (tiff.len < 8) return null;
    const big: bool = if (tiff[0] == 0x4D and tiff[1] == 0x4D)
        true
    else if (tiff[0] == 0x49 and tiff[1] == 0x49)
        false
    else
        return null;
    if (readU16(tiff[2..4], big) != 42) return null;
    const ifd0_off = readU32(tiff[4..8], big);

    var ifd0: [MAX_IFD_ENTRIES]Entry = undefined;
    const n0 = parseIfd(tiff, ifd0_off, big, &ifd0) orelse return null;

    var make: ?[]const u8 = null;
    var model: ?[]const u8 = null;
    var sub_off: ?u32 = null;
    for (ifd0[0..n0]) |e| {
        switch (e.tag) {
            0x010F => make = asciiValue(tiff, e),
            0x0110 => model = asciiValue(tiff, e),
            0x8769 => {
                if (e.ty == 4 and e.count == 1) sub_off = e.raw;
            },
            else => {},
        }
    }
    const make_v = make orelse return null;
    const model_v = model orelse return null;
    if (make_v.len == 0 or model_v.len == 0) return null;
    const sub_off_v = sub_off orelse return null;

    var sub: [MAX_IFD_ENTRIES]Entry = undefined;
    const ns = parseIfd(tiff, sub_off_v, big, &sub) orelse return null;
    var dt_orig: ?[]const u8 = null;
    var subsec_orig: ?[]const u8 = null;
    for (sub[0..ns]) |e| {
        switch (e.tag) {
            0x9003 => dt_orig = asciiValue(tiff, e),
            0x9291 => subsec_orig = asciiValue(tiff, e),
            else => {},
        }
    }
    const dt_v = dt_orig orelse return null;
    const subsec_v = subsec_orig orelse return null;
    if (dt_v.len == 0 or subsec_v.len == 0) return null;

    var pos: usize = 0;
    const parts = [_][]const u8{ make_v, model_v, dt_v, subsec_v };
    for (parts) |p| {
        if (pos + p.len + 1 > out.len) return null;
        @memcpy(out[pos..][0..p.len], p);
        pos += p.len;
        out[pos] = 0;
        pos += 1;
    }
    const dims = std.fmt.bufPrint(out[pos..], "{d}x{d}", .{ width, height }) catch return null;
    return pos + dims.len;
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn putU16(buf: []u8, v: u16, big: bool) void {
    if (big) std.mem.writeInt(u16, buf[0..2], v, .big) else std.mem.writeInt(u16, buf[0..2], v, .little);
}

fn putU32(buf: []u8, v: u32, big: bool) void {
    if (big) std.mem.writeInt(u32, buf[0..4], v, .big) else std.mem.writeInt(u32, buf[0..4], v, .little);
}

const Buf = struct {
    data: [512]u8 = undefined,
    len: usize = 0,
    fn append(self: *Buf, bytes: []const u8) void {
        @memcpy(self.data[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

/// Build a minimal EXIF APP1 payload (II or MM) with the four required tags.
/// `inline_subsec` forces the subsec value to the 4-byte inline form.
fn buildTestExif(big: bool, inline_subsec: bool) Buf {
    var b = Buf{};
    const make = "HUAWEI\x00";
    const model = "ELS-AN10\x00";
    const dt = "2026:08:02 11:39:40\x00";
    const subsec = "229502\x00";

    b.append("Exif\x00\x00");
    const tiff_start = b.len;
    b.append(if (big) "MM" else "II");
    const magic_off = b.len;
    b.append(&.{ 0, 0 });
    putU16(b.data[magic_off..], 42, big);
    const ifd0_off_pos = b.len;
    b.append(&.{ 0, 0, 0, 0 });
    const ifd0_off = b.len; // IFD0 starts here (after the 8-byte header)
    putU32(b.data[ifd0_off_pos..], @intCast(ifd0_off - tiff_start), big);

    // IFD0: 4 entries (Make, Model, DateTime, ExifOffset)
    putU16(b.data[b.len..], 4, big);
    b.len += 2;
    const e0 = b.len;
    var zeros: [4 * 12]u8 = @splat(0);
    b.append(&zeros);
    const sub_off = ifd0_off + 2 + 4 * 12 + 4;
    const data_start = ifd0_off + 2 + 4 * 12 + 4 + 2 + 2 * 12 + 4;
    var ep = e0;
    var s0 = data_start;
    var dt_off: usize = 0;
    putU16(b.data[ep..], 0x010F, big);
    putU16(b.data[ep + 2 ..], 2, big);
    putU32(b.data[ep + 4 ..], @intCast(make.len), big);
    putU32(b.data[ep + 8 ..], @intCast(s0 - tiff_start), big);
    ep += 12;
    s0 += make.len;
    putU16(b.data[ep..], 0x0110, big);
    putU16(b.data[ep + 2 ..], 2, big);
    putU32(b.data[ep + 4 ..], @intCast(model.len), big);
    putU32(b.data[ep + 8 ..], @intCast(s0 - tiff_start), big);
    ep += 12;
    s0 += model.len;
    putU16(b.data[ep..], 0x0132, big);
    putU16(b.data[ep + 2 ..], 2, big);
    putU32(b.data[ep + 4 ..], @intCast(dt.len), big);
    dt_off = s0;
    putU32(b.data[ep + 8 ..], @intCast(s0 - tiff_start), big);
    ep += 12;
    s0 += dt.len;
    putU16(b.data[ep..], 0x8769, big);
    putU16(b.data[ep + 2 ..], 4, big);
    putU32(b.data[ep + 4 ..], 1, big);
    putU32(b.data[ep + 8 ..], @intCast(sub_off - tiff_start), big);
    ep += 12;
    putU32(b.data[ep..], 0, big); // no next IFD
    b.len = ep + 4;

    // Sub-IFD: 2 entries (DateTimeOriginal, SubsecTimeOriginal)
    putU16(b.data[b.len..], 2, big);
    b.len += 2;
    const s1 = b.len;
    const sub_zeros: [2 * 12 + 4]u8 = @splat(0);
    b.append(&sub_zeros);
    var sp = s1;
    putU16(b.data[sp..], 0x9003, big);
    putU16(b.data[sp + 2 ..], 2, big);
    putU32(b.data[sp + 4 ..], @intCast(dt.len), big);
    putU32(b.data[sp + 8 ..], @intCast(dt_off - tiff_start), big);
    sp += 12;
    putU16(b.data[sp..], 0x9291, big);
    putU16(b.data[sp + 2 ..], 2, big);
    if (inline_subsec) {
        putU32(b.data[sp + 4 ..], 3, big); // 3 chars inline ("229")
        var vb = [_]u8{ '2', '2', '9', 0 };
        @memcpy(b.data[sp + 8 ..][0..3], vb[0..3]);
    } else {
        putU32(b.data[sp + 4 ..], @intCast(subsec.len), big);
        putU32(b.data[sp + 8 ..], @intCast(dt_off + dt.len - tiff_start), big);
    }
    sp += 12;
    putU32(b.data[sp..], 0, big);
    b.len = sp + 4;

    // Data area
    b.append(make);
    b.append(model);
    b.append(dt);
    b.append(subsec);

    return b;
}

test "buildMaterial: little-endian (II), offset strings" {
    var buf: [160]u8 = undefined;
    const exif = buildTestExif(false, false);
    const payload = exif.data[0..exif.len];
    const len = buildMaterial(payload, 2592, 3840, &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("HUAWEI\x00ELS-AN10\x002026:08:02 11:39:40\x00229502\x002592x3840", buf[0..len]);
}

test "buildMaterial: big-endian (MM)" {
    var buf: [160]u8 = undefined;
    const exif = buildTestExif(true, false);
    const payload = exif.data[0..exif.len];
    const len = buildMaterial(payload, 2592, 3840, &buf) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqualStrings("HUAWEI\x00ELS-AN10\x002026:08:02 11:39:40\x00229502\x002592x3840", buf[0..len]);
}

test "buildMaterial: inline ASCII value (count <= 4)" {
    var buf: [160]u8 = undefined;
    const exif = buildTestExif(false, true);
    const payload = exif.data[0..exif.len];
    const len = buildMaterial(payload, 2592, 3840, &buf) orelse return error.TestUnexpectedNull;
    // inline subsec is "229" (3 chars)
    try std.testing.expect(std.mem.endsWith(u8, buf[0..len], "\x00229\x002592x3840"));
}

test "buildMaterial: rejects non-EXIF payload" {
    var buf: [160]u8 = undefined;
    try std.testing.expect(buildMaterial("not exif at all........", 10, 10, &buf) == null);
}

test "buildMaterial: rejects missing required tags" {
    var buf: [160]u8 = undefined;
    const exif = buildTestExif(false, false);
    const payload = exif.data[0..exif.len];
    var p: [512]u8 = undefined;
    const pl = payload.len;
    @memcpy(p[0..pl], payload);
    // Corrupt the Make tag into something else.
    const tiff = p[6..pl];
    const ifd0_off = std.mem.readInt(u32, tiff[4..8], .little);
    std.mem.writeInt(u16, tiff[ifd0_off + 2 ..][0..2], 0x0001, .little); // Make -> 0x0001
    try std.testing.expect(buildMaterial(p[0..pl], 2592, 3840, &buf) == null);
}

test "buildMaterial: rejects malformed TIFF" {
    var buf: [160]u8 = undefined;
    var payload: [32]u8 = @splat(0);
    @memcpy(payload[0..6], "Exif\x00\x00");
    payload[6] = 'X'; // bad endian marker
    try std.testing.expect(buildMaterial(&payload, 10, 10, &buf) == null);
}
