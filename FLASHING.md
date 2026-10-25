# Frija Flash 0.2.0 — experimental

Frija Flash is a native macOS Samsung firmware flashing companion for Frija
Mac. The suite contains two apps: download and decrypt with **Frija Mac**,
then select extracted packages in **Frija Flash**. Both are universal Apple
Silicon/Intel builds targeting macOS 14 or later. Neither is Apple notarized.

**No physical-device flash has been validated for this release.** Passing
software and mock-transport tests does not establish that a particular phone
will flash successfully. There is no measured success rate yet.

## Intended workflow

For the reported SM-F776U / VZW → SM-F776U1 / XAA conversion:

1. Back up the phone. Download the **SM-F776U1 / XAA** package in Frija Mac.
2. Extract the downloaded ZIP in Finder. Keep the original `.tar.md5` files.
3. Open Frija Flash, put one phone in Download Mode, connect it directly to
   the Mac by USB, and select **Detect device**. This reads identity only.
4. Select **U ↔ U1 conversion** and enter **SM-F776U1** as the target model.
5. Import the extracted firmware folder or choose BL, AP, CP, and exactly one
   CSC/HOME_CSC file individually. Import prefers HOME_CSC if both exist;
   choose CSC explicitly when that is the package you intend to flash.
6. Select **Validate packages**. Checksums and archive structure are checked
   offline. Review any model/revision errors before proceeding.
7. Select **Review flash…**. Review the device, target, packages, and possible
   data erasure. Type the displayed `FLASH <connected model>` phrase, then
   select **Start flash** only when you intend to write the device.
8. Keep USB connected and the app open. A backend completion message means
   the protocol returned success; verify that the phone boots and behaves
   correctly before treating the conversion as successful.

The app permits the corresponding U/U1 pair of the same model family. That
name check is not proof of hardware compatibility. It does not override the
phone's own signature or rollback enforcement, SIM-unlock a phone, or promise
that the final active CSC will be XAA. The flashed firmware and device setup
control the resulting carrier configuration. No forced sales-code opcode is
sent. This release requires the phone to support the DVIF diagnostic query;
older devices that do not return model, serial identity, and bootloader build
remain blocked from flashing.

CSC packages can reset the phone. HOME_CSC does not guarantee data preservation
in a carrier conversion. The app exposes neither an explicit NAND erase nor
partition-table replacement operation. Firmware writes can still erase data
or leave the phone unbootable if incompatible or interrupted.

## Implementation

The Mac apps are SwiftUI. A bundled Rust helper implements USB communication
through `nusb` and a vendored copy of `samloader-odin` 2.2.0, pinned to upstream
revision `4dfea027767f3268e70dc130f169d459bd153cbf`.

The patched Windows Odin executable was statically inspected as a behavioral
reference. It is not executed, bundled, or redistributed. The native helper
does not reproduce Odin's PC-side model/carrier/SHA256 rejection paths. It
uses explicit same-model or corresponding U/U1 policy instead, and always
verifies each original `.tar.md5` package before opening a flashing session.
MD5 detects accidental corruption; it does not prove firmware authenticity.

Changes to the vendored protocol library:

- Ignore embedded package PIT data and retain the device's active partition
  map. Upstream 2.2.0 otherwise uploads a package PIT automatically.
- Reject unmapped firmware entries before partition writes instead of silently
  skipping them and potentially reporting partial success.
- Export mock fixtures only when the test-only `mock` feature is enabled.
- Replace the upstream PIT-upload test with a device-map-preservation test.

The helper rechecks the connected model, serial identity, CSC, and bootloader
against the reviewed device. It rejects multiple Download Mode devices,
unrelated model pairs, missing identity, older target bootloader revisions,
duplicate slots, renamed non-MD5 packages, inconsistent model filenames,
unsafe/nonregular TAR entries, and checksum failures. Partition size checks
stay enabled. Packages are revalidated on Start flash, not just when selected.

Device identity is kept in memory and in a short-lived, mode-0600 request file
inside a mode-0700 temporary directory, removed when the helper returns. The
activity log redacts the device serial. There is no network code or telemetry
in the flashing helper. Detection does not upload data to a service.

Normal close/quit is blocked while a flash is running. There is no pause or
resume for firmware writes; a forced shutdown, app crash, cable disconnect, or
power loss can still interrupt them. Package validation/detection can be
canceled before flashing.

## Build and test

Install a Swift 6.2+ Apple toolchain and Rust stable with both Mac targets:

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
bash scripts/test-flash.sh
bash scripts/build-flash.sh
```

Cargo dependencies are pinned by `Backend/Cargo.lock`. Source for the protocol
and PIT parser is in `Backend/vendor/`; notices are in `NOTICE` and `Licenses/`.
The release build does not enable the `mock` feature. The native helper has
only `version`, `detect`, `inspect REQUEST.json`, and `flash REQUEST.json`
commands. There is no generic command passthrough or shell execution.

Build outputs include a standalone flasher ZIP and a suite ZIP with both apps.
Extract the suite and keep the two apps together (for example in Applications)
so Frija Mac's **Open Frija Flash** button can find its companion.

## Current testing boundary

Software tests cover U/U1 policy, unrelated models, revision checks, corrupted
packages, package slots, same-device binding, helper integrity, process-output
handling, mock protocol transfers, and preservation of the existing PIT. A
synthetic package set is flashed over a mock transport through handshake,
partition mapping, transfer, completion, and reboot.

No real phone has been flashed with Frija Flash, including SM-F776U. Intel is
compiled but has not been run on an Intel Mac. The immediate hardware test is
**Detect device**, which establishes whether the Mac can read your phone's
Download Mode identity. A subsequent real flash needs a device owner willing
to test with backed-up data and a known-working recovery path.
