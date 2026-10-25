# Frija Mac

An independent native macOS Samsung firmware downloader, inspired by Frija.
Requires macOS 14 Sonoma or later. The packaged app supports Apple Silicon
and Intel. No Python, Homebrew, Windows, or .NET runtime is needed to run it.

**[Download the Mac app](https://github.com/supremevega/frija-mac/releases/tag/v0.1.0)**

Development release: ad-hoc signed, not notarized. See
[validation and testing limits](VALIDATION.md) before use.

## Use

1. Unzip `Frija-Mac-0.1.0-universal.zip` and open `Frija Mac.app`.
   You may move it into Applications. This development build is ad-hoc signed,
   not Apple notarized; macOS may require approval in System Settings →
   Privacy & Security → Open Anyway when opening a downloaded copy.
2. Enter the exact model number and three-character CSC/sales code. For
   example, `SM-S928B` and `EUX`. Different model suffixes can identify different
   hardware. Find your model in Settings → About phone, and your CSC in
   Software information → Service provider software version.
3. Choose Latest, then Check firmware. The app queries Samsung’s public FOTA
   listing and FUS package information. An IMEI or serial number is not needed.
4. Choose a download folder and click Download. The package downloads,
   decrypts, and passes a full ZIP CRC check before the finished ZIP appears.
5. Show in Finder opens the result. Installing/flashing firmware requires
   another tool and is outside this app’s scope.

Manual mode accepts a full `PDA/CSC/MODEM` or `PDA/CSC/MODEM/PDA` version.
Samsung can remove older builds; a listed historical version is not a promise
that its download remains available. Support depends on Samsung serving the
specific model/CSC combination. Watches and tablets can be entered by model,
but only the documented phone combinations have been tested live.

## Pause and resume

Pause keeps the encrypted `.partial` file and `.resume.json` identity record
in your chosen folder. Resume uses both to ensure the partial file matches the
firmware. To resume after quitting, check the same model/CSC/version, choose
the same folder, and click Download. If Latest has changed, use Manual with
the previous full version from the resume record.

The transfer uses sequential 8 MiB range requests with bounded memory and
retries transient connection errors. The current incomplete chunk may be
downloaded again after a pause. Decryption and verification restart if paused.
Existing finished files are never overwritten. Keep enough disk space for
both the encrypted package and its decrypted ZIP, approximately twice the
package size. Some current Samsung packages exceed 20 GB.

If ZIP verification fails repeatedly, move the `.partial` and `.resume.json`
files out of the folder before retrying to fetch a clean package.

## Privacy and transport

Only recent model/CSC pairs are saved in macOS UserDefaults. There is no
analytics, account, or device-identifier collection. The activity log stays in
memory unless you copy it. The resume record contains public package metadata
and its decryption key, not personal device data.

Metadata and authentication use HTTPS. Samsung’s Smart download endpoint
serves the encrypted package over HTTP, with a narrowly scoped ATS exception
for `cloud-neofussvr.samsungmobile.com`. ZIP CRC verification detects corrupt
archives; it does not establish cryptographic authenticity of firmware.

## Source and builds

The source is a Swift 6.2+ package with no third-party build dependencies:

- `Sources/FrijaCore`: device/version validation, current Smart FUS protocol,
  range downloads, resume identity, AES ENC2/ENC4 decryption, ZIP checks.
- `Sources/FrijaMac`: SwiftUI desktop app.
- `Sources/FrijaCLI`: optional command-line client and 16-byte live probe.
- `Tests/FrijaCoreTests`: synthetic encrypted-ZIP integration tests, resume,
  cancellation, validation, and integrity failure cases.

With Apple Command Line Tools or Xcode and Swift 6.2+ installed:

```sh
swift build
swift test
bash scripts/build.sh
```

`scripts/build.sh` builds both CPU architectures and creates an ad-hoc signed
app, ZIP, and CLI in `dist/`. It uses SwiftPM’s native build system so a full
Xcode install is not required. On Command Line Tools installs where Swift
Testing is not found automatically, use `bash scripts/test.sh`.

CLI examples:

```sh
./dist/frija check SM-S928B EUX
./dist/frija probe SM-S928B EUX
./dist/frija download SM-S928B EUX /path/to/firmware-folder
```

The probe downloads only the first 16 bytes and validates the decrypted ZIP
header. It does not validate a complete production firmware download.

## Relationship to Frija

The original Frija repository publishes updater XML files and Windows
releases; it does not include the application source needed for a direct port.

This is a new macOS implementation, not an official Frija release or a
binary conversion. It does not reproduce Windows USB device detection,
parallel downloading, or Frija’s automatic updater. Protocol references and
licenses are in `NOTICE` and `Licenses/`, also included inside the app bundle.

See `VALIDATION.md` for checks performed on this build and their limits.

## License

Apache License 2.0. Protocol adaptations retain their upstream MIT and
Apache notices in `NOTICE` and `Licenses/`.
