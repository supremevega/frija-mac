import Foundation

public struct TransferProgress: Sendable {
    public enum Phase: String, Sendable { case downloading, decrypting, verifying, complete }
    public let phase: Phase
    public let completed: Int64
    public let total: Int64
    public var fraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }
}

public enum Transfer {
    private static let chunkSize: Int64 = 8 * 1024 * 1024

    @concurrent
    public static func download(_ firmware: Firmware, using service: FirmwareService, to destination: URL,
                                progress: @Sendable (TransferProgress) async -> Void) async throws -> URL {
        let fm = FileManager.default
        let output = destination.appendingPathComponent(firmware.outputName)
        let partial = destination.appendingPathComponent(firmware.filename + ".partial")
        let manifest = destination.appendingPathComponent(firmware.filename + ".resume.json")
        let decrypted = destination.appendingPathComponent(firmware.outputName + ".decrypting")
        guard !fm.fileExists(atPath: output.path) else {
            throw FirmwareError("\(firmware.outputName) already exists. Choose another folder or move the existing file.")
        }
        guard !fm.fileExists(atPath: decrypted.path) else {
            // Only a matching manifest makes this an app-owned scratch file.
            guard let saved = try? JSONDecoder().decode(Firmware.self, from: Data(contentsOf: manifest)), saved == firmware else {
                throw FirmwareError("A decryption temporary file already exists. Move it or choose another folder.")
            }
            try fm.removeItem(at: decrypted)
            return try await download(firmware, using: service, to: destination, progress: progress)
        }
        if fm.fileExists(atPath: partial.path) {
            guard let saved = try? JSONDecoder().decode(Firmware.self, from: Data(contentsOf: manifest)), saved == firmware else {
                throw FirmwareError("The partial download does not match this firmware. Choose another folder or move the old partial file.")
            }
        } else {
            try JSONEncoder().encode(firmware).write(to: manifest, options: .atomic)
            guard fm.createFile(atPath: partial.path, contents: nil) else { throw FirmwareError("Could not create the download file.") }
        }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        var offset = Int64(try file.seekToEnd())
        guard offset <= firmware.size else { throw FirmwareError("The partial download is larger than the expected firmware. Move it and retry.") }
        // Use actual free bytes. Some macOS volumes report zero for the
        // purgeable-capacity resource key even with hundreds of GB free.
        if let available = (try fm.attributesOfFileSystem(forPath: destination.path)[.systemFreeSize] as? NSNumber)?.int64Value {
            let required = firmware.size - offset + firmware.size + 100 * 1024 * 1024
            guard available >= required else { throw FirmwareError("Not enough disk space. This download needs about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) free for the package and decrypted ZIP.") }
        }
        await progress(.init(phase: .downloading, completed: offset, total: firmware.size))
        if offset < firmware.size { try await service.authorize(firmware) }
        while offset < firmware.size {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, firmware.size) - 1
            let data = try await fetchWithRetry(firmware, using: service, start: offset, end: end)
            try Task.checkCancellation()
            try file.write(contentsOf: data)
            try file.synchronize()
            offset += Int64(data.count)
            await progress(.init(phase: .downloading, completed: offset, total: firmware.size))
        }
        try file.close()
        do {
            try await decrypt(firmware, input: partial, output: decrypted, progress: progress)
            await progress(.init(phase: .verifying, completed: 0, total: 1))
            try await verifyZIP(decrypted)
            try Task.checkCancellation()
            try fm.moveItem(at: decrypted, to: output)
            try? fm.removeItem(at: partial)
            try? fm.removeItem(at: manifest)
            await progress(.init(phase: .complete, completed: firmware.size, total: firmware.size))
            return output
        } catch {
            try? fm.removeItem(at: decrypted)
            throw error
        }
    }

    private static func fetchWithRetry(_ firmware: Firmware, using service: FirmwareService,
                                       start: Int64, end: Int64) async throws -> Data {
        for attempt in 0..<3 {
            do { return try await service.chunk(firmware, start: start, end: end) }
            catch {
                try Task.checkCancellation()
                guard attempt < 2, let networkError = error as? URLError,
                      [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost].contains(networkError.code) else { throw error }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
        throw FirmwareError("Download failed. Retry to resume the saved partial file.")
    }

    @concurrent
    public static func decrypt(_ firmware: Firmware, input: URL, output: URL,
                               progress: @Sendable (TransferProgress) async -> Void) async throws {
        guard !FileManager.default.fileExists(atPath: output.path) else { throw FirmwareError("The decryption output file already exists.") }
        let source = try FileHandle(forReadingFrom: input)
        defer { try? source.close() }
        let size = Int64(try source.seekToEnd())
        guard size == firmware.size, !firmware.isEncrypted || size % 16 == 0 else {
            throw FirmwareError("The downloaded package is incomplete or has an invalid size.")
        }
        try source.seek(toOffset: 0)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw FirmwareError("Could not create the decrypted ZIP.") }
        let target = try FileHandle(forWritingTo: output)
        defer { try? target.close() }
        var count: Int64 = 0
        while count < size {
            try Task.checkCancellation()
            let length = Int(min(chunkSize, size - count))
            guard let block = try source.read(upToCount: length), block.count == length else { throw FirmwareError("The firmware file ended unexpectedly.") }
            count += Int64(block.count)
            let plaintext = firmware.isEncrypted ? try Crypto.aes(block, key: firmware.key, decrypt: true, padding: count == size) : block
            try target.write(contentsOf: plaintext)
            await progress(.init(phase: .decrypting, completed: count, total: size))
        }
        try target.synchronize()
    }

    @concurrent
    public static func verifyZIP(_ file: URL) async throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-tqq", file.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        do {
            while task.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            if task.isRunning { task.terminate() }
            throw error
        }
        guard task.terminationStatus == 0 else { throw FirmwareError("ZIP integrity verification failed. The encrypted download was kept so you can inspect or retry it.") }
    }
}
