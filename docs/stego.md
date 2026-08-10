# Stego-facing specification

> Framework — full RFC-style spec lands in a later iteration (KDF, PRNG
> budget, STC construction, cost model, wet-pixel rules, test vectors).

## Security model

- Kerckhoffs: algorithm fully public; secrecy rests entirely on the key
  (`stego_secret`).
- With the key secret, an analyst who knows every algorithm cannot locate or
  verify the payload (keyed PRNG scatter) nor decrypt it (ChaCha20-Poly1305).
- With the key public, any carrier-modifying scheme is information-theoretically
  detectable; this is a hard bound, not an engineering choice.
- Embedding targets the DCT coefficient domain so the watermark survives
  lossy re-compression at equal or higher quality.

## Carrier contract (JPEG)

See `README.md`. Canonical rules:

- Y component only; zig-zag AC band [1..32].
- `2 ≤ |coef| ≤ 254` → carrier magnitude (stored as u8, exact).
- Asymmetric modification costs at the boundaries so the candidate set is
  invariant under allowed ±1 modifications.
- Block-major layout, `bpp = 31`.

## To be specified

- HKDF-SHA256 derivation (AEAD key / seed_P / seed_M).
- PRNG consumption budget (exact order, cross-language identical).
- STC parity-check matrix construction + constraint height.
- Distortion cost model.
- Test vectors appendix.
