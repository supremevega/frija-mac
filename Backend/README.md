# Frija Flash native helper

A small JSON-lines CLI around vendored samloader-odin 2.2.0. The protocol
source is pinned to 4dfea027767f3268e70dc130f169d459bd153cbf; local changes
are described in ../FLASHING.md and ../NOTICE. The original Windows Odin
executable is not bundled or executed.

`version` and `detect` require no request file. `inspect REQUEST.json` checks
four original packages offline. `flash REQUEST.json` repeats those checks,
requires a captured expected device and the exact typed confirmation phrase,
rechecks the live device, and then flashes over the same connection. See the
Swift FlashRequest type for the JSON schema.

Build with Cargo and the committed lockfile. Release builds omit the mock
feature. Run `cargo test --locked --workspace --features mock` for software and
protocol-simulation tests. Those tests do not establish real-device support.
