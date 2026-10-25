import Foundation
import FrijaCore

@main struct CLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, ["check", "download", "probe"].contains(args[0]) else {
            print("Usage: frija check MODEL CSC [PDA/CSC/MODEM]\n       frija download MODEL CSC OUTPUT_FOLDER [PDA/CSC/MODEM]\n       frija probe MODEL CSC  # authorize and decrypt first 16 bytes only")
            return
        }
        do {
            let device = try Device(model: args[1], region: args[2])
            let isDownload = args[0] == "download"
            guard !isDownload || args.count >= 4 else { throw FirmwareError("Supply an output folder.") }
            let version = args.count > (isDownload ? 4 : 3) ? args[isDownload ? 4 : 3] : ""
            let service = FirmwareService()
            let info = try await service.check(device: device, version: version)
            print("\(device.model) / \(device.region)\n\(info.version)\n\(info.filename)\n\(info.size) bytes (\(info.displaySize))")
            if args[0] == "probe" {
                try await service.authorize(info)
                let block = try await service.chunk(info, start: 0, end: 15)
                let plain = info.isEncrypted ? try Crypto.aes(block, key: info.key, decrypt: true) : block
                guard plain.starts(with: [0x50, 0x4b, 0x03, 0x04]) else { throw FirmwareError("Firmware header did not decrypt to a ZIP.") }
                print("Live authorization, byte ranges, AES decryption: OK (16 bytes downloaded)")
            }
            if isDownload {
                let url = try await Transfer.download(info, using: service, to: URL(fileURLWithPath: args[3], isDirectory: true)) { progress in
                    print("\(progress.phase.rawValue): \(Int(progress.fraction * 100))%")
                }
                print("Saved: \(url.path)")
            }
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
