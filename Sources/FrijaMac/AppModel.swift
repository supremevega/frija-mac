import AppKit
import Observation
import FrijaCore

struct SavedDevice: Codable, Identifiable {
    let model: String
    let region: String
    var id: String { "\(model)/\(region)" }
}

@Observable final class AppModel {
    var model = ""
    var region = ""
    var manual = false
    var version = ""
    var firmware: Firmware?
    var destination: URL?
    var output: URL?
    var busy = false
    var checking = false
    var paused = false
    var progress: TransferProgress?
    var message = "Enter a model number and CSC to get started."
    var error: String?
    var logs: [String] = []
    var showLog = false
    var recent: [SavedDevice] = []
    private let service = FirmwareService()
    private var operation: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "recentDevices"), let saved = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            recent = saved
        }
    }
    var validDevice: Bool { (try? Device(model: model, region: region)) != nil }
    var canCheck: Bool { validDevice && !busy && (!manual || !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var phaseTitle: String {
        if checking { return "Checking Samsung’s servers" }
        if paused { return "Download paused" }
        switch progress?.phase {
        case .downloading: return "Downloading firmware"
        case .decrypting: return "Decrypting package"
        case .verifying: return "Verifying ZIP integrity"
        case .complete: return "Ready in Finder"
        case nil: return firmware == nil ? "Ready when you are" : "Firmware available"
        }
    }
    func invalidate() {
        guard !busy else { return }
        firmware = nil
        output = nil
        progress = nil
        paused = false
        error = nil
        message = "Check availability for this model and CSC."
    }
    func select(_ device: SavedDevice) {
        guard !busy else { return }
        model = device.model
        region = device.region
        manual = false
        version = ""
        invalidate()
    }
    func addLog(_ text: String) {
        logs.append("\(Date.now.formatted(date: .omitted, time: .standard))  \(text)")
        if logs.count > 100 { logs.removeFirst(logs.count - 100) }
    }
    func check() {
        guard canCheck else { return }
        busy = true
        checking = true
        firmware = nil
        output = nil
        progress = nil
        paused = false
        error = nil
        message = "Finding the firmware package and download information…"
        operation = Task {
            defer { busy = false; checking = false; operation = nil }
            do {
                let device = try Device(model: model, region: region)
                addLog("Checking \(device.model) / \(device.region).")
                let info = try await service.check(device: device, version: manual ? version : "")
                try Task.checkCancellation()
                firmware = info
                message = "\(info.displaySize) available directly from Samsung."
                let saved = SavedDevice(model: device.model, region: device.region)
                recent.removeAll { $0.id == saved.id }
                recent.insert(saved, at: 0)
                recent = Array(recent.prefix(8))
                if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: "recentDevices") }
                addLog("Found \(info.filename) (\(info.size) bytes).")
            } catch {
                if Task.isCancelled { message = "Firmware check canceled." }
                else { self.error = error.localizedDescription; message = "Could not check firmware."; addLog(error.localizedDescription) }
            }
        }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose where to save firmware packages. Partial downloads resume in the same folder."
        if panel.runModal() == .OK { destination = panel.url }
    }
    func download() {
        guard let firmware, !busy else { return }
        if destination == nil { chooseFolder() }
        guard let destination else { return }
        busy = true
        checking = false
        paused = false
        error = nil
        output = nil
        message = "Partial downloads are saved automatically."
        addLog("Saving to \(destination.lastPathComponent).")
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                output = try await Transfer.download(firmware, using: service, to: destination) { update in
                    await self.updateProgress(update)
                }
                message = "Downloaded, decrypted, and ZIP integrity verified."
                addLog("Finished. ZIP integrity verified.")
            } catch {
                if Task.isCancelled {
                    paused = true
                    message = "Your partial file is saved. Resume with the same folder."
                    addLog("Paused. Partial download preserved.")
                } else {
                    self.error = error.localizedDescription
                    message = "The download could not finish. Saved partial data can be resumed."
                    addLog(error.localizedDescription)
                }
            }
        }
    }
    func updateProgress(_ update: TransferProgress) {
        if progress?.phase != update.phase { addLog(update.phase.rawValue.capitalized + ".") }
        progress = update
    }
    func pause() { operation?.cancel() }
    func reveal() {
        if let output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else if let destination { NSWorkspace.shared.open(destination) }
    }
    func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs.joined(separator: "\n"), forType: .string)
    }
}
