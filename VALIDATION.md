# Validation — October 25, 2026

## Automated checks

All 14 Swift Testing tests passed, including parameterized invalid CSC inputs:

- Device input normalization and invalid model/CSC handling.
- Three-/four-part firmware version normalization.
- Current nonce signature checked against an independent OpenSSL AES vector.
- Server metadata parsing and ENC2/ENC4 decryption-key derivation.
- Unavailable responses, malformed XML, and unsafe filenames rejected.
- Complete synthetic encrypted ZIP lookup/download/decryption/verification.
- Resume from a nonzero partial-file offset.
- Existing final files and mismatched partial downloads preserved.
- Incorrect Content-Range responses rejected.
- Decryption across an 8 MiB chunk boundary with final PKCS#7 padding.
- Invalid ZIP rejected.
- Cancellation during the transfer preserves the existing partial file.

## Live Samsung checks

For each pair below, the native client queried public FOTA metadata and Smart
FUS package metadata, authorized a download, requested bytes 0–15, decrypted
the block, and confirmed the ZIP local-file signature `50 4b 03 04`.

| Model / CSC | PDA build returned | Encrypted package bytes |
| --- | --- | ---: |
| SM-S928B / EUX | S928BXXU6EZIF | 20,198,115,216 |
| SM-S931U1 / XAA | S931U1UEUCDZIF | 18,644,098,368 |
| SM-G991B / BTU | G991BXXSJHZC2 | 9,064,413,840 |

The packaged release CLI also passed the SM-S928B/EUX probe.

## Native interface and packaging

- Launched the app extracted from the final ZIP on the Apple Silicon host.
- Entered SM-S928B/EUX in the interface and clicked Check firmware.
- Confirmed the available build, PDA/CSC/modem, 20.2 GB size, and enabled
  Download button in the native UI; visually inspected the rendered window.
- Built arm64 and x86_64 executables; verified both CPU slices with `file`.
- Verified both slices declare a macOS 14.0 minimum deployment target.
- Verified the extracted app’s ad-hoc signature with
  `codesign --verify --deep --strict`.
- Verified the ZIP archive with `unzip -tqq`.
- The distribution ZIP excludes Finder extended metadata, avoiding extra
  metadata added by cloud-backed Documents folders.

## Limits

No complete multi-gigabyte production firmware package was downloaded.
End-to-end package processing was tested with a synthetic encrypted ZIP;
production-server testing covered metadata, authorization, byte ranges, and
first-block decryption. Intel was compiled but not run. Older macOS releases
were not available for runtime testing. Watches, tablets, USB autodetection,
and device flashing were not tested. This is a development release, ad-hoc
signed rather than Apple notarized.

## Frija Flash 0.2.0 experimental companion

On October 25, 2026, all **23 Swift tests and 41 Rust tests passed** (64 total).
The Rust count includes 14 helper tests, 26 protocol tests, and one PIT-parser
test. The helper's integration tests verify four original `.tar.md5` files,
reject corrupted/mixed-model/duplicate-slot input, reject a changed device,
and exercise a complete mock flash and normal reboot. The mock advertises a
U model and accepts the corresponding U1 plan; it does not emulate the real
SM-F776U bootloader's security or hardware behavior.

The modified upstream PIT test proves the original mock partition map remains
active despite a different embedded PIT. The Swift tests cover conversion
policy, bootloader rollback rejection, device identity, helper checksums,
process output drained before exit, and literal path handling. The original
firmware-downloader tests still pass.

Both UI apps and the Rust helper were built as universal arm64/x86_64 binaries.
After extracting the suite ZIP, both app bundles passed strict ad-hoc signature
verification, the helper's SHA256 matched the bundled manifest, and the archive
passed `unzip -tqq`. The release helper reports `simulation: false` and
`pitUpload: false`. The release build does not enable the mock feature.

The native Frija Flash window was opened and visually inspected. Conversion
mode accepts the requested SM-F776U1 target. Clicking Detect device with no
Samsung Download Mode device connected produced the expected error, and
Validate/Review controls remained disabled. The bundled helper's command-line
no-device check returned the same controlled error. No firmware was written.

**No real-device flash, SM-F776U connection, carrier conversion, or post-flash
boot has been tested. No model is certified by these software tests.** Intel
was compiled but not run. There is no defensible numerical success probability
until hardware testing supplies evidence. The first practical hardware check
is whether Detect device reads the owner's Download Mode model and bootloader.
