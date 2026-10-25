import Foundation
import CryptoKit

public enum FlashMode: String, Codable, Sendable, CaseIterable {
    case standard, conversion
    public var title: String { self == .standard ? "Same model" : "U ↔ U1 conversion" }
}
public enum FlashSlot: String, Codable, Sendable, CaseIterable { case BL, AP, CP, CSC }
public struct FlashDevice: Codable, Equatable, Sendable {
    public var model: String
    public var serial: String
    public var bootloader: String
    public var csc: String
    public init(model: String, serial: String, bootloader: String, csc: String) {
        self.model = model; self.serial = serial; self.bootloader = bootloader; self.csc = csc
    }
}
public struct FlashPackage: Codable, Equatable, Sendable {
    public var slot: FlashSlot
    public var path: String
    public init(slot: FlashSlot, path: String) { self.slot = slot; self.path = path }
}
public struct FlashPackageInfo: Codable, Sendable {
    public var slot: FlashSlot
    public var path: String
    public var size: UInt64
    public var md5: String
    public var entries: [String]
    public var hasPit: Bool
    public var mayWipe: Bool
}
public struct FlashInspection: Codable, Sendable {
    public var targetModel: String
    public var targetBootloader: UInt32
    public var packages: [FlashPackageInfo]
    public var mayWipe: Bool
}
public struct FlashRequest: Codable, Sendable {
    public var targetModel: String
    public var mode: FlashMode
    public var packages: [FlashPackage]
    public var expectedDevice: FlashDevice?
    public var confirmation: String?
    public init(targetModel: String, mode: FlashMode, packages: [FlashPackage], expectedDevice: FlashDevice? = nil, confirmation: String? = nil) {
        self.targetModel = targetModel.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.mode = mode; self.packages = packages; self.expectedDevice = expectedDevice; self.confirmation = confirmation
    }
}
public struct FlashEvent: Codable, Sendable {
    public var event: String
    public var message: String?
    public var device: FlashDevice?
    public var inspection: FlashInspection?
    public var phase: String?
    public var completed: UInt64?
    public var total: UInt64?
    public var name: String?
}
public enum FlashPolicy {
    public static func revision(_ build: String) -> UInt32? {
        let chars = Array(build.uppercased())
        guard chars.count >= 5, build.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return UInt32(String(chars[chars.count - 5]), radix: 36)
    }
    public static func validate(device: FlashDevice, target: String, mode: FlashMode, targetRevision: UInt32) throws {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let source = device.model.uppercased()
        func family(_ model: String) -> String? {
            if model.hasSuffix("U1") { return String(model.dropLast(2)) }
            if model.hasSuffix("U") { return String(model.dropLast()) }
            return nil
        }
        if mode == .standard {
            guard source == target else { throw FirmwareError("The package target differs from the connected model. Use conversion mode only for corresponding U/U1 variants.") }
        } else {
            guard source != target, let root = family(source), root == family(target) else {
                throw FirmwareError("U/U1 conversion requires corresponding variants of the same model family, such as SM-F776U and SM-F776U1.")
            }
        }
        guard !device.serial.isEmpty, let revision = revision(device.bootloader) else { throw FirmwareError("Device identity and bootloader revision must be available before flashing.") }
        guard targetRevision >= revision else { throw FirmwareError("The package has an older bootloader revision than the device. Downgrade is blocked.") }
    }
}

public struct HelperResult: Sendable { public var exitCode: Int32; public var events: [FlashEvent] }

// Access to the child process and cancellation state is synchronized; no other
// mutable references escape this container. Foundation permits terminate()
// from another thread while its pipe is read by the operation thread.
private final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { process.terminate() }
    }
}
public enum FlashHelper {
    @concurrent
    public static func verify(executable: URL, manifest: URL) async throws {
        let data = try Data(contentsOf: executable, options: .mappedIfSafe)
        let manifest = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: manifest))
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == manifest["sha256"] else { throw FirmwareError("The bundled flashing helper failed its integrity check. Reinstall the app.") }
    }
    @concurrent
    public static func run(executable: URL, command: String, request: FlashRequest? = nil,
                           onEvent: @Sendable (FlashEvent) async -> Void) async throws -> HelperResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FrijaFlash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        var arguments = [command]
        if let request {
            let file = folder.appendingPathComponent("request.json")
            try JSONEncoder().encode(request).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            arguments.append(file.path)
        }
        return try await execute(executable: executable, arguments: arguments, onEvent: onEvent)
    }
    @concurrent
    public static func execute(executable: URL, arguments: [String],
                               onEvent: @Sendable (FlashEvent) async -> Void) async throws -> HelperResult {
        let control = ProcessControl()
        return try await withTaskCancellationHandler {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try control.start(process)
            try? pipe.fileHandleForWriting.close()
            defer { try? pipe.fileHandleForReading.close() }
            var pending = Data()
            var events: [FlashEvent] = []
            func decode(_ line: Data) -> FlashEvent? { try? JSONDecoder().decode(FlashEvent.self, from: line) }
            while let data = try pipe.fileHandleForReading.read(upToCount: 4096), !data.isEmpty {
                pending.append(data)
                guard pending.count < 4 * 1024 * 1024 else { control.cancel(); throw FirmwareError("Flashing helper returned an oversized response.") }
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.subdata(in: pending.startIndex..<newline)
                    pending.removeSubrange(pending.startIndex...newline)
                    if let event = decode(line) { events.append(event); await onEvent(event) }
                    if events.count > 2000 { events.removeFirst(1000) }
                }
            }
            if let event = decode(pending) { events.append(event); await onEvent(event) }
            process.waitUntilExit()
            try Task.checkCancellation()
            return HelperResult(exitCode: process.terminationStatus, events: events)
        } onCancel: { control.cancel() }
    }
}
