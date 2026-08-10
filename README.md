# zig-image-codec

PNG & JPEG image decoder for **Zig 0.16** that exposes *stego carrier bytes*
instead of raw pixels.

## Why carrier bytes?

Lossless LSB embedding in the spatial domain dies under any lossy
re-compression.  To build a watermark that survives JPEG re-encoding you must
embed in the domain that JPEG preserves: the **quantized DCT coefficients**.
This library stops the JPEG pipeline *before* IDCT / color conversion and
returns the coefficient magnitudes as a flat byte array — the exact shape a
PRNG-scatter / matrix-embedding stego layer consumes.

For PNG the carrier is the raw scanline pixel buffer (lossless carrier).

## Supported formats

| Format | Decode | Encode (tests) | Carrier |
|---|---|---|---|
| PNG  (8-bit, color types 0/2/4/6) | ✅ | ✅ | spatial pixel bytes |
| JPEG (baseline DCT, SOF0)        | ✅ | ✅ | Y quantized AC coefficient magnitudes |

Unsupported JPEG variants are rejected with explicit errors:
`error.UnsupportedJpeg` (progressive SOF2, CMYK/APP14), `error.NotJpeg`,
`error.NotPng`.

## API

```zig
pub const Decoded = struct {
    carriers: []u8,          // carrier byte array (stego consumes this)
    width: u32,              // PNG: pixel grid width; JPEG: blocks_x
    height: u32,             // PNG: pixel grid height; JPEG: blocks_y
    bpp: u8,                 // PNG: 1..4; JPEG: 31 (AC band [1..32])
    salt: ?[16]u8,           // KDF salt from metadata (tEXt / COM)
};

pub fn decodePng(allocator: std.mem.Allocator, data: []const u8) !Decoded;
pub fn decodeJpeg(allocator: std.mem.Allocator, data: []const u8) !Decoded;
```

## JPEG carrier contract

- Only the **luminance (Y)** component is used (most stable under
  re-encoding, finer quantization, most stealthy).
- Zig-zag **AC band [1..32]** (DC and the most fragile high frequencies are
  skipped).
- Coefficient magnitudes with `|coef| ∈ [2, 254]` become the carrier;
  values outside the range are stored as placeholders and are never
  candidates (F5 non-shrinkability: a ±1 modification never creates or
  destroys a zero).
- Blocks are laid out **block-major** (row-major over the 8×8 DCT grid),
  `bpp = 31` magnitudes per block.

## Build & test

```sh
zig build            # static lib + module export
zig build test       # unit tests (pure std, no deps)
zig fmt --check .    # formatting gate (CI)
```

Requires Zig 0.16.0. Pure std — no third-party runtime dependencies.

The JPEG decoder is cross-validated against libjpeg: `src/oracle_*.zig` +
`src/fixtures/oracle_*.jpg` hold the expected Y quantized coefficients for a
color 4:2:0 and a grayscale fixture. Regenerate with
`python tools/gen_jpeg_fixtures.py` (see `requirements.txt`).

See `docs/stego.md` for the full stego-facing specification (KDF, PRNG
budget, STC construction, cost model, cross-language alignment).
