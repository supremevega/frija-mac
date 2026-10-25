// Copyright 2026 Frija Mac contributors. Licensed under Apache-2.0.
// Native transport: samloader-odin 2.2.0; see NOTICE and vendor/.
use samloader_odin::nusb::MaybeFuture;
use samloader_odin::{
    FlashEvent, FlashManager, FlashProgress, NusbBackend, OdinConnection, RebootMode, UsbBackend,
    set_progress,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::HashSet,
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path},
    sync::Mutex,
    time::Instant,
};

type Result<T> = std::result::Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn emit(value: serde_json::Value) {
    println!("{value}");
    let _ = std::io::stdout().flush();
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Device {
    model: String,
    serial: String,
    bootloader: String,
    csc: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Package {
    slot: String,
    path: String,
}
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    target_model: String,
    mode: String,
    packages: Vec<Package>,
    expected_device: Option<Device>,
    confirmation: Option<String>,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PackageInfo {
    slot: String,
    path: String,
    size: u64,
    md5: String,
    entries: Vec<String>,
    has_pit: bool,
    may_wipe: bool,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Inspection {
    target_model: String,
    target_bootloader: u32,
    packages: Vec<PackageInfo>,
    may_wipe: bool,
}

fn normalized_model(s: &str) -> Result<String> {
    let model = s.trim().to_ascii_uppercase();
    if !model.starts_with("SM-")
        || !(7..=20).contains(&model.len())
        || !model[3..].bytes().all(|x| x.is_ascii_alphanumeric())
    {
        return Err("Enter an exact Samsung SM- model number.".into());
    }
    Ok(model)
}
fn revision(build: &str) -> Result<u32> {
    let s = build.trim().to_ascii_uppercase();
    let c = s
        .chars()
        .rev()
        .nth(4)
        .ok_or("Bootloader build is unavailable or too short.")?;
    if !s.bytes().all(|x| x.is_ascii_alphanumeric()) {
        return Err("Unrecognized bootloader build.".into());
    }
    c.to_digit(36)
        .ok_or("Cannot determine bootloader revision.".into())
}
fn pair_root(model: &str) -> Option<&str> {
    model.strip_suffix("U1").or_else(|| model.strip_suffix('U'))
}
fn validate_device(req: &Request, device: &Device, target_revision: u32) -> Result<()> {
    let source = normalized_model(&device.model)?;
    let target = normalized_model(&req.target_model)?;
    match req.mode.as_str() {
        "standard" if source == target => {}
        "conversion"
            if source != target
                && pair_root(&source).is_some()
                && pair_root(&source) == pair_root(&target) => {}
        "standard" => {
            return Err(format!(
                "Device is {source}, package target is {target}. Select U/U1 conversion only for a corresponding U/U1 pair."
            ));
        }
        "conversion" => {
            return Err(
                "Conversion requires the corresponding U and U1 variants of the same model family."
                    .into(),
            );
        }
        _ => return Err("Unknown flashing mode.".into()),
    }
    if device.serial.is_empty() {
        return Err("The device did not return an identity. Flashing is disabled.".into());
    }
    let current = revision(&device.bootloader)?;
    if target_revision < current {
        return Err(format!(
            "Bootloader downgrade rejected: device revision {current}, package revision {target_revision}."
        ));
    }
    Ok(())
}
fn verify_md5(path: &Path, notify: bool) -> Result<(u64, String)> {
    let mut f = File::open(path).map_err(err)?;
    let size = f.metadata().map_err(err)?.len();
    if size < 1024 {
        return Err("Package is too small to contain a TAR and MD5 footer.".into());
    }
    let tail_start = size.saturating_sub(1024);
    f.seek(SeekFrom::Start(tail_start)).map_err(err)?;
    let mut tail = Vec::new();
    f.read_to_end(&mut tail).map_err(err)?;
    let split = tail
        .iter()
        .rposition(|x| *x == 0)
        .ok_or("No TAR/MD5 footer boundary found.")?
        + 1;
    let footer = &tail[split..];
    if footer.len() < 32
        || !footer.is_ascii()
        || !footer[..32].iter().all(u8::is_ascii_hexdigit)
        || (footer.len() > 32 && !footer[32].is_ascii_whitespace())
    {
        return Err("Invalid .tar.md5 footer.".into());
    }
    let expected = std::str::from_utf8(&footer[..32])
        .map_err(err)?
        .to_ascii_lowercase();
    let payload = tail_start + split as u64;
    if payload % 512 != 0 {
        return Err("TAR payload is not aligned to 512-byte records.".into());
    }
    f.seek(SeekFrom::Start(0)).map_err(err)?;
    let mut hash = fast_md5::Md5::new();
    let mut remaining = payload;
    let mut buf = vec![0; 1024 * 1024];
    let mut tick = Instant::now();
    while remaining > 0 {
        let n = (remaining as usize).min(buf.len());
        f.read_exact(&mut buf[..n]).map_err(err)?;
        hash.update(&buf[..n]);
        remaining -= n as u64;
        if notify && tick.elapsed().as_millis() > 250 {
            emit(
                json!({"event":"progress","phase":"validating","completed":payload-remaining,"total":payload}),
            );
            tick = Instant::now();
        }
    }
    let actual = hash
        .finalize()
        .iter()
        .map(|x| format!("{x:02x}"))
        .collect::<String>();
    if actual != expected {
        return Err(format!(
            "MD5 verification failed for {}. Download a clean package.",
            path.file_name().unwrap_or_default().to_string_lossy()
        ));
    }
    Ok((payload, actual))
}
fn inspect(req: &Request, notify: bool) -> Result<Inspection> {
    let target = normalized_model(&req.target_model)?;
    if !["standard", "conversion"].contains(&req.mode.as_str()) {
        return Err("Unknown flashing mode.".into());
    }
    let mut slots = HashSet::new();
    let mut paths = HashSet::new();
    let mut output = Vec::new();
    let mut target_revision = None;
    if req.packages.len() != 4 {
        return Err("Select BL, AP, CP, and exactly one CSC or HOME_CSC package.".into());
    }
    for p in &req.packages {
        if !["BL", "AP", "CP", "CSC"].contains(&p.slot.as_str()) || !slots.insert(p.slot.clone()) {
            return Err("Duplicate or unsupported package slot.".into());
        }
        let path = std::fs::canonicalize(&p.path).map_err(err)?;
        if !paths.insert(path.clone()) || !path.is_file() {
            return Err("Package files must be distinct regular files.".into());
        }
        let name = path
            .file_name()
            .and_then(|x| x.to_str())
            .ok_or("Invalid package filename.")?;
        if !name.ends_with(".tar.md5") {
            return Err(
                "Only original .tar.md5 packages are accepted; extract the Frija ZIP first.".into(),
            );
        }
        let prefix = if p.slot == "CSC" {
            name.starts_with("CSC_") || name.starts_with("HOME_CSC_")
        } else {
            name.starts_with(&(p.slot.clone() + "_"))
        };
        if !prefix {
            return Err(format!("{} does not belong in the {} slot.", name, p.slot));
        }
        let root = &target[3..];
        if !name.split('_').any(|token| {
            token.starts_with(root)
                && token
                    .as_bytes()
                    .get(root.len())
                    .is_some_and(u8::is_ascii_alphabetic)
        }) {
            return Err(format!("{} does not identify target model {target}.", name));
        }
        if p.slot == "BL" {
            let build = name.split('_').nth(1).ok_or("Missing BL build number.")?;
            target_revision = Some(revision(build)?);
        }
        if notify {
            emit(
                json!({"event":"log","message":format!("Verifying {} package MD5 and archive structure…",p.slot)}),
            );
        }
        let (payload, md5) = verify_md5(&path, notify)?;
        let file = File::open(&path).map_err(err)?;
        let mut archive = tar::Archive::new(file.take(payload));
        let mut entries = Vec::new();
        let mut seen = HashSet::new();
        let mut has_pit = false;
        for entry in archive.entries().map_err(err)? {
            let entry = entry.map_err(err)?;
            if entry.header().entry_type().is_dir() {
                continue;
            }
            if !entry.header().entry_type().is_file() {
                return Err("Package contains a link or unsupported archive entry.".into());
            }
            let name = entry.path().map_err(err)?.into_owned();
            if name.is_absolute()
                || name.components().any(|x| {
                    matches!(
                        x,
                        Component::ParentDir | Component::RootDir | Component::Prefix(_)
                    )
                })
            {
                return Err("Package contains an unsafe archive path.".into());
            }
            let base = name
                .file_name()
                .and_then(|s| s.to_str())
                .ok_or("Invalid archive member name.")?
                .to_string();
            let normalized = base
                .strip_suffix(".lz4")
                .unwrap_or(&base)
                .to_ascii_lowercase();
            if !seen.insert(normalized.clone()) {
                return Err("Package contains duplicate partition filenames.".into());
            }
            has_pit |= normalized.ends_with(".pit");
            entries.push(base);
            if entries.len() > 4096 {
                return Err("Too many archive entries.".into());
            }
        }
        if entries.is_empty() {
            return Err("Package contains no firmware entries.".into());
        }
        let may_wipe = p.slot == "CSC" && !name.starts_with("HOME_CSC_");
        output.push(PackageInfo {
            slot: p.slot.clone(),
            path: path.to_string_lossy().into_owned(),
            size: std::fs::metadata(&path).map_err(err)?.len(),
            md5,
            entries,
            has_pit,
            may_wipe,
        });
    }
    let may_wipe = output.iter().any(|p| p.may_wipe);
    Ok(Inspection {
        target_model: target,
        target_bootloader: target_revision.ok_or("Missing BL package.")?,
        packages: output,
        may_wipe,
    })
}
fn connection() -> Result<(OdinConnection, Device)> {
    let mut devices = samloader_odin::nusb::list_devices()
        .wait()
        .map_err(err)?
        .filter(|d| d.vendor_id() == 0x04e8 && [0x6601, 0x685d, 0x68c3].contains(&d.product_id()));
    let usb=devices.next().ok_or("No Samsung device found in Download Mode. Connect one phone directly by USB and try Detect again.")?;
    if devices.next().is_some() {
        return Err("More than one Download Mode device is connected. Connect only the phone you intend to flash.".into());
    }
    let mut conn = OdinConnection::new(Box::new(NusbBackend::new(usb, false).map_err(err)?));
    let info = conn.query_device_info().map_err(|e| {
        format!("Cannot read the device identity over USB: {e}. Flashing remains disabled.")
    })?;
    let device = Device {
        model: info.model.unwrap_or_default(),
        serial: info.serial_number.unwrap_or_default(),
        bootloader: info.bootloader_version.unwrap_or_default(),
        csc: info.sales_code.unwrap_or_default(),
    };
    normalized_model(&device.model)?;
    if device.serial.is_empty() || device.bootloader.is_empty() {
        return Err("Device identity or bootloader version is unavailable.".into());
    }
    Ok((conn, device))
}
struct Reporter(Mutex<(u64, u64, Instant)>);
impl FlashProgress for Reporter {
    fn set_length(&self, total: u64) {
        if let Ok(mut s) = self.0.lock() {
            *s = (0, total, Instant::now());
        }
    }
    fn inc(&self, bytes: u64) {
        if let Ok(mut s) = self.0.lock() {
            s.0 += bytes;
            if s.2.elapsed().as_millis() > 200 {
                emit(json!({"event":"progress","phase":"flashing","completed":s.0,"total":s.1}));
                s.2 = Instant::now();
            }
        }
    }
    fn println(&self, msg: &str) {
        emit(json!({"event":"log","message":msg}));
    }
    fn on_event(&self, event: FlashEvent<'_>) {
        match event {
            FlashEvent::PartitionStart { name, size } => {
                emit(json!({"event":"partition","name":name,"total":size}))
            }
            FlashEvent::PartitionEnd(name) => {
                emit(json!({"event":"log","message":format!("Finished {name}")}))
            }
            FlashEvent::PartitionFail(name) => {
                emit(json!({"event":"log","message":format!("Failed {name}")}))
            }
            _ => {}
        }
    }
}
fn run() -> Result<()> {
    let args = std::env::args().collect::<Vec<_>>();
    let command = args.get(1).map(String::as_str).unwrap_or("version");
    if command == "version" {
        emit(
            json!({"event":"version","version":"0.2.0","protocol":"samloader-odin 2.2.0","pitUpload":false,"simulation":false}),
        );
        return Ok(());
    }
    if command == "detect" {
        let (_, device) = connection()?;
        emit(json!({"event":"device","device":device}));
        return Ok(());
    }
    if !["inspect", "flash"].contains(&command) {
        return Err(
            "Supported commands: version, detect, inspect REQUEST.json, flash REQUEST.json".into(),
        );
    }
    let path = args.get(2).ok_or("Missing request file.")?;
    let req: Request = serde_json::from_reader(File::open(path).map_err(err)?).map_err(err)?;
    let inspection = inspect(&req, true)?;
    if command == "inspect" {
        emit(json!({"event":"inspection","inspection":inspection}));
        return Ok(());
    }
    let expected = req
        .expected_device
        .as_ref()
        .ok_or("Detect a device before flashing.")?;
    if req.confirmation.as_deref() != Some(&format!("FLASH {}", expected.model)) {
        return Err("Explicit typed flash confirmation is missing.".into());
    }
    let (conn, device) = connection()?;
    flash_on_connection(&req, &inspection, conn, &device)?;
    Ok(())
}
fn flash_on_connection(
    req: &Request,
    inspection: &Inspection,
    mut conn: OdinConnection,
    device: &Device,
) -> Result<()> {
    let expected = req
        .expected_device
        .as_ref()
        .ok_or("Detect a device before flashing.")?;
    if req.confirmation.as_deref() != Some(&format!("FLASH {}", expected.model)) {
        return Err("Explicit typed flash confirmation is missing.".into());
    }
    if device != expected {
        return Err("Connected device identity or bootloader changed after detection. Detect and review again.".into());
    }
    validate_device(req, device, inspection.target_bootloader)?;
    set_progress(Reporter(Mutex::new((0, 0, Instant::now()))));
    conn.init().map_err(err)?;
    let mut session = conn.begin_session().map_err(err)?;
    let packages = inspection
        .packages
        .iter()
        .map(|p| p.path.clone())
        .collect::<Vec<_>>();
    // Our robust MD5 verifier ran in inspect(), immediately before this session.
    // No PIT upload, erase, size bypass, or sales-code command is exposed.
    FlashManager::new(&mut session)
        .packages(&packages)
        .skip_md5(true)
        .skip_size_check(false)
        .erase(false)
        .reboot_mode(RebootMode::Normal)
        .execute()
        .map_err(err)?;
    emit(
        json!({"event":"complete","message":"Backend reports flash complete and normal reboot requested. Confirm the phone boots successfully."}),
    );
    Ok(())
}

fn main() {
    if let Err(message) = run() {
        emit(json!({"event":"error","message":message}));
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request() -> Request {
        Request {
            target_model: "SM-F776U1".into(),
            mode: "conversion".into(),
            packages: vec![],
            expected_device: None,
            confirmation: None,
        }
    }
    fn device() -> Device {
        Device {
            model: "SM-F776U".into(),
            serial: "TEST-ONLY".into(),
            bootloader: "F776USQU3AZH7".into(),
            csc: "VZW".into(),
        }
    }
    #[test]
    fn permits_corresponding_u_u1() {
        assert!(validate_device(&request(), &device(), 3).is_ok());
    }
    #[test]
    fn blocks_other_family() {
        let mut r = request();
        r.target_model = "SM-S928U1".into();
        assert!(validate_device(&r, &device(), 3).is_err());
    }
    #[test]
    fn blocks_downgrade() {
        assert!(validate_device(&request(), &device(), 2).is_err());
    }
    #[test]
    fn blocks_conversion_in_standard_mode() {
        let mut r = request();
        r.mode = "standard".into();
        assert!(validate_device(&r, &device(), 3).is_err());
    }
    #[test]
    fn rejects_missing_identity() {
        let mut d = device();
        d.serial.clear();
        assert!(validate_device(&request(), &d, 3).is_err());
    }
    #[test]
    fn accepts_letter_revision() {
        assert_eq!(revision("S928U1UESAAZH7").unwrap(), 10);
    }
    #[test]
    fn rejects_unknown_mode() {
        let mut r = request();
        r.mode = "force".into();
        assert!(validate_device(&r, &device(), 3).is_err());
    }
    #[test]
    fn cannot_inspect_empty_selection() {
        assert!(inspect(&request(), false).is_err());
    }
}

#[cfg(test)]
mod integration_tests {
    use super::*;
    use samloader_odin::{DeviceProfile, MockBackend};
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(std::path::PathBuf);
    impl Fixture {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "frija-helper-test-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&p).unwrap();
            Self(p)
        }
        fn package(&self, slot: &str, entry: &str) -> Package {
            let mut tar = tar::Builder::new(Vec::new());
            let content = vec![0x5a; 4096];
            let mut header = tar::Header::new_gnu();
            header.set_size(content.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            tar.append_data(&mut header, entry, &content[..]).unwrap();
            let mut data = tar.into_inner().unwrap();
            let mut h = fast_md5::Md5::new();
            h.update(&data);
            let footer = h
                .finalize()
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>();
            data.extend_from_slice(format!("{footer}\n").as_bytes());
            let p = self.0.join(format!("{slot}_F776U1UEU3AZH7_test.tar.md5"));
            std::fs::write(&p, data).unwrap();
            Package {
                slot: slot.into(),
                path: p.to_string_lossy().into_owned(),
            }
        }
        fn request(&self) -> Request {
            Request {
                target_model: "SM-F776U1".into(),
                mode: "conversion".into(),
                packages: vec![
                    self.package("BL", "xbl.elf"),
                    self.package("AP", "boot.img"),
                    self.package("CP", "modem.bin"),
                    self.package("CSC", "cache.img"),
                ],
                expected_device: None,
                confirmation: None,
            }
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn verifies_all_four_original_packages() {
        let f = Fixture::new();
        let i = inspect(&f.request(), false).unwrap();
        assert_eq!(i.packages.len(), 4);
        assert_eq!(i.target_bootloader, 3);
        assert!(i.may_wipe);
    }
    #[test]
    fn corrupt_package_fails_before_usb() {
        let f = Fixture::new();
        let r = f.request();
        let p = &r.packages[0].path;
        let mut b = std::fs::read(p).unwrap();
        b[600] ^= 1;
        std::fs::write(p, b).unwrap();
        assert!(inspect(&r, false).unwrap_err().contains("MD5"));
    }
    #[test]
    fn rejects_mixed_model_packages() {
        let f = Fixture::new();
        let mut r = f.request();
        r.target_model = "SM-S928U1".into();
        assert!(inspect(&r, false).is_err());
    }
    #[test]
    fn rejects_duplicate_slots() {
        let f = Fixture::new();
        let mut r = f.request();
        r.packages[1].slot = "BL".into();
        assert!(inspect(&r, false).is_err());
    }
    #[test]
    fn mock_transport_flashes_verified_package_and_reboots() {
        let f = Fixture::new();
        let profile = DeviceProfile::builder()
            .model("SM-F776U")
            .build_version("F776USQU3AZH7")
            .default_sales_code("VZW")
            .build();
        let pit = samloader_odin::samloader_pit::PitData::new(&profile.default_pit).unwrap();
        let entries = pit
            .entries
            .iter()
            .map(|e| e.flash_filename.to_string_lossy().into_owned())
            .filter(|n| !n.is_empty() && !n.ends_with(".pit") && n != "super.img")
            .take(4)
            .collect::<Vec<_>>();
        assert_eq!(entries.len(), 4);
        let mut r = f.request();
        r.packages = ["BL", "AP", "CP", "CSC"]
            .iter()
            .zip(entries)
            .map(|(s, n)| f.package(s, &n))
            .collect();
        let mut conn = OdinConnection::new(Box::new(MockBackend::with_profile(profile, false)));
        let info = conn.query_device_info().unwrap();
        let d = Device {
            model: info.model.unwrap(),
            serial: info.serial_number.unwrap(),
            bootloader: info.bootloader_version.unwrap(),
            csc: info.sales_code.unwrap(),
        };
        r.expected_device = Some(d.clone());
        r.confirmation = Some("FLASH SM-F776U".into());
        let i = inspect(&r, false).unwrap();
        flash_on_connection(&r, &i, conn, &d).unwrap();
    }
    #[test]
    fn changed_device_is_rejected_before_session() {
        let f = Fixture::new();
        let mut r = f.request();
        let d = Device {
            model: "SM-F776U".into(),
            serial: "ONE".into(),
            bootloader: "F776USQU3AZH7".into(),
            csc: "VZW".into(),
        };
        r.expected_device = Some(d.clone());
        r.confirmation = Some("FLASH SM-F776U".into());
        let mut changed = d;
        changed.serial = "TWO".into();
        let conn = OdinConnection::new(Box::new(MockBackend::new(false)));
        assert!(flash_on_connection(&r, &inspect(&r, false).unwrap(), conn, &changed).is_err());
    }
}
