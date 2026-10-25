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
