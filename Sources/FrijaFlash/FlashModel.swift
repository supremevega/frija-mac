import AppKit
import Observation
import FrijaCore

@Observable final class FlashModel {
    var mode = FlashMode.standard
    var targetModel = ""
    var files: [FlashSlot: URL] = [:]
    var device: FlashDevice?
    var inspection: FlashInspection?
    var busy = false
    var flashing = false
    var status = "Connect one Samsung device in Download Mode."
    var error: String?
    var logs: [String] = []
    var progress: Double?
    var phase = ""
    var partition = ""
    var showConfirmation = false
    var confirmation = ""
    var lastCompleted = false
    private var operation: Task<Void, Never>?
    private var helperVerified = false
    var request: FlashRequest {
        FlashRequest(targetModel: targetModel, mode: mode, packages: FlashSlot.allCases.compactMap { slot in
            files[slot].map { FlashPackage(slot: slot, path: $0.path) }
        }, expectedDevice: device)
    }
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/frija-flash-helper") }
    var readyToValidate: Bool { !busy && files.count == 4 && !targetModel.trimmingCharacters(in: .whitespaces).isEmpty }
    var eligibilityError: String? {
        guard let device, let inspection else { return "Detect a device and validate all four packages first." }
        do { try FlashPolicy.validate(device: device, target: targetModel, mode: mode, targetRevision: inspection.targetBootloader); return nil }
        catch { return error.localizedDescription }
    }
    var readyToFlash: Bool { !busy && eligibilityError == nil }
    var confirmationPhrase: String { "FLASH \(device?.model ?? "DEVICE")" }
    func invalidate() {
        guard !busy else { return }
        inspection = nil; lastCompleted = false; error = nil; progress = nil
        status = "Package selection changed. Validate again before flashing."
    }
    func log(_ text: String) {
        var text = text
        if let serial = device?.serial, !serial.isEmpty { text = text.replacingOccurrences(of: serial, with: "[device identity]") }
        logs.append(text)
        if logs.count > 400 { logs.removeFirst(logs.count - 400) }
    }
    func checkHelper() async throws {
        if helperVerified { return }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw FirmwareError("The native USB helper is missing. Open the packaged Frija Flash app, or build it with scripts/build-flash.sh.")
        }
        try await FlashHelper.verify(executable: helperURL, manifest: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/HelperManifest.json"))
        helperVerified = true
    }
    func receive(_ event: FlashEvent) {
        switch event.event {
        case "device": device = event.device
        case "inspection": inspection = event.inspection
        case "error": error = event.message; if let message = event.message { log(message) }
        case "log": if let message = event.message { log(message) }
        case "progress":
            phase = event.phase ?? ""
            if let done = event.completed, let total = event.total, total > 0 { progress = min(1, Double(done) / Double(total)) }
        case "partition": partition = event.name ?? ""; progress = 0; status = "Writing \(partition)…"
        case "complete": lastCompleted = true; progress = 1; log(event.message ?? "Backend reports completion.")
        default: break
        }
    }
    func detect() {
        guard !busy else { return }
        busy = true; device = nil; error = nil; progress = nil
        status = "Reading device identity over USB…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await checkHelper()
                let result = try await FlashHelper.run(executable: helperURL, command: "detect") { event in await self.receive(event) }
                guard result.exitCode == 0, device != nil else { throw FirmwareError(error ?? "Device detection failed.") }
                status = "Device detected. No firmware has been written."
                log("Detected \(device!.model), bootloader \(device!.bootloader), CSC \(device!.csc).")
                if targetModel.isEmpty { targetModel = device!.model }
            } catch { report(error) }
        }
    }
    func validate() {
        guard readyToValidate else { return }
        let request = request
        inspection = nil; busy = true; error = nil; progress = nil; phase = "validating"
        status = "Verifying package checksums and archive structure…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                try await checkHelper()
                let result = try await FlashHelper.run(executable: helperURL, command: "inspect", request: request) { event in await self.receive(event) }
                guard result.exitCode == 0, inspection != nil else { throw FirmwareError(error ?? "Package validation failed.") }
                progress = nil
                status = "All four packages passed MD5 and archive checks."
                log(status)
            } catch { report(error) }
        }
    }
    func beginFlash() {
        guard readyToFlash, confirmation == confirmationPhrase else { return }
        var request = request
        request.confirmation = confirmation
        showConfirmation = false; confirmation = ""; busy = true; flashing = true; error = nil; progress = nil; lastCompleted = false
        status = "Rechecking packages and connected device before writing…"
        operation = Task {
            defer { busy = false; flashing = false; operation = nil }
            do {
                try await checkHelper()
                let result = try await FlashHelper.run(executable: helperURL, command: "flash", request: request) { event in await self.receive(event) }
                guard result.exitCode == 0, lastCompleted else { throw FirmwareError(error ?? "Flashing failed. Keep the device in Download Mode and save the log.") }
                status = "Backend reports completion. Check that the phone boots successfully."
                inspection = nil
            } catch { report(error); inspection = nil }
        }
    }
    func report(_ error: Error) {
        if Task.isCancelled { status = "Operation canceled. No flash was started." }
        else {
            self.error = error.localizedDescription; status = "Operation could not complete."
            if logs.last != error.localizedDescription { log(error.localizedDescription) }
        }
    }
    func cancel() { if !flashing { operation?.cancel() } }
    func choose(_ slot: FlashSlot) {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "Select the original \(slot.rawValue) .tar.md5 file. Extract the Frija ZIP first."
        if panel.runModal() == .OK, let url = panel.url { files[slot] = url; invalidate() }
    }
    func importFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose an extracted firmware folder containing BL, AP, CP and CSC/HOME_CSC packages."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".tar.md5") }
            var found: [FlashSlot: URL] = [:]
            for slot in FlashSlot.allCases {
                let prefix = slot == .CSC ? "HOME_CSC_" : slot.rawValue + "_"
                let matches = urls.filter { $0.lastPathComponent.hasPrefix(prefix) }
                if matches.count == 1 { found[slot] = matches[0] }
                else if slot == .CSC {
                    let csc = urls.filter { $0.lastPathComponent.hasPrefix("CSC_") }
                    if csc.count == 1 { found[slot] = csc[0] }
                }
            }
            files = found; invalidate()
            if found.count != 4 { error = "Some package slots are missing or ambiguous. Choose those files individually." }
        } catch { report(error) }
    }
    func copyLog() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string) }
}
