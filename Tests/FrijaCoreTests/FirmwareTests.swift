import Foundation
import Testing
@testable import FrijaCore

private let zipFixture = Data(base64Encoded: "UEsDBBQAAAAAAAAAIVwGd09oFgAAABYAAAAMAAAAZmlybXdhcmUudHh0RmlybXdhcmUgdGVzdCBmaXh0dXJlClBLAQIUAxQAAAAAAAAAIVwGd09oFgAAABYAAAAMAAAAAAAAAAAAAACAAQAAAABmaXJtd2FyZS50eHRQSwUGAAAAAAEAAQA6AAAAQAAAAAAA")!
private let testVersion = "S928BXXU6TEST/S928BOXM6TEST/S928BXXU6TEST/S928BXXU6TEST"
private let testLogic = "0123456789abcdef"
private let testKey = Crypto.md5(Crypto.logicCheck(testVersion, nonce: testLogic))
private let encryptedFixture = try! Crypto.aes(zipFixture, key: testKey, decrypt: false, padding: true)

private func metadata(filename: String = "SM-S928B_1_20260101000000_abcdefghij_fac.zip.enc4", status: String = "200") -> Data {
    Data("""
    <FUSMsg><FUSBody><Results><Status>\(status)</Status></Results><Put>
    <BINARY_SW_VERSION><Data>\(testVersion)</Data></BINARY_SW_VERSION>
    <BINARY_NAME><Data>\(filename)</Data></BINARY_NAME><MODEL_PATH><Data>T1/SM-S928B/EUX/</Data></MODEL_PATH>
    <BINARY_BYTE_SIZE><Data>\(encryptedFixture.count)</Data></BINARY_BYTE_SIZE>
    <LOGIC_VALUE_FACTORY><Data>\(testLogic)</Data></LOGIC_VALUE_FACTORY>
    <DEVICE_MODEL_TYPE><Data>Smart Phone</Data></DEVICE_MODEL_TYPE>
    </Put></FUSBody></FUSMsg>
    """.utf8)
}
private func info() throws -> Firmware {
    try Firmware.parse(metadata(), device: Device(model: "SM-S928B", region: "EUX"), requestedVersion: testVersion)
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        var fields = ["NONCE": "0123456789abcdef"]
        var status = 200
        var data = Data()
        if path.hasSuffix("version.xml") {
            data = Data("<versioninfo><firmware><version><latest>\(testVersion)</latest></version></firmware></versioninfo>".utf8)
        } else if path.hasSuffix("BinaryInform.do") {
            data = metadata()
        } else if path.hasSuffix("BinaryInitForMass.do") {
            data = Data("<FUSMsg><FUSBody><Results><Status>200</Status></Results></FUSBody></FUSMsg>".utf8)
        } else if path.hasSuffix("BinaryForMass.do") {
            let range = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-")
            let start = Int(range[0])!, end = Int(range[1])!
            data = encryptedFixture.subdata(in: start..<(end + 1))
            status = 206
            fields["Content-Range"] = "bytes \(start)-\(end)/\(encryptedFixture.count)"
            if request.value(forHTTPHeaderField: "X-Mock-Mode") == "bad-range" { fields["Content-Range"] = "bytes 0-15/16" }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private func service(badRange: Bool = false) -> FirmwareService {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockProtocol.self]
    if badRange { config.httpAdditionalHeaders = ["X-Mock-Mode": "bad-range"] }
    return FirmwareService(session: URLSession(configuration: config))
}
private func temporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

@Test func deviceNormalization() throws {
    let device = try Device(model: " sm-s928b ", region: " eux\n")
    #expect(device.model == "SM-S928B")
    #expect(device.region == "EUX")
}
@Test(arguments: ["../", "EUX/", "", " EU", "<x>"])
func rejectsInvalidRegion(_ region: String) {
    #expect(throws: FirmwareError.self) { try Device(model: "SM-S928B", region: region) }
}
@Test func versionNormalization() throws {
    #expect(try FirmwareService.normalizeVersion("pda/csc/modem") == "PDA/CSC/MODEM/PDA")
    #expect(try FirmwareService.normalizeVersion("PDA/CSC//PDA") == "PDA/CSC/PDA/PDA")
    #expect(throws: FirmwareError.self) { try FirmwareService.normalizeVersion("PDA") }
    #expect(throws: FirmwareError.self) { try FirmwareService.normalizeVersion("PDA/CSC/MODEM/") }
}
@Test func nonceSignatureMatchesOpenSSL() throws {
    #expect(try Crypto.signNonce("0123456789abcdef") == "ff9af17d365c75e46d98c431f2176e97")
}
@Test func parsesMetadataAndKey() throws {
    let value = try info()
    #expect(value.key == testKey)
    #expect(value.size == encryptedFixture.count)
    #expect(value.outputName.hasSuffix(".zip"))
}
@Test func rejectsUnavailableAndUnsafeFirmware() throws {
    let device = try Device(model: "SM-S928B", region: "EUX")
    #expect(throws: FirmwareError.self) { try Firmware.parse(metadata(status: "102"), device: device, requestedVersion: testVersion) }
    #expect(throws: FirmwareError.self) { try Firmware.parse(metadata(filename: "../firmware.zip.enc4"), device: device, requestedVersion: testVersion) }
    #expect(throws: FirmwareError.self) { try Firmware.parse(Data("<broken".utf8), device: device, requestedVersion: testVersion) }
}
@Test func mockLookupAndDownload() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let client = service()
    let firmware = try await client.check(device: Device(model: "SM-S928B", region: "EUX"))
    let output = try await Transfer.download(firmware, using: client, to: folder) { _ in }
    #expect(try Data(contentsOf: output) == zipFixture)
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(firmware.filename + ".partial").path))
}
@Test func resumesExistingPartial() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let firmware = try info()
    try encryptedFixture.prefix(16).write(to: folder.appendingPathComponent(firmware.filename + ".partial"))
    try JSONEncoder().encode(firmware).write(to: folder.appendingPathComponent(firmware.filename + ".resume.json"))
    let output = try await Transfer.download(firmware, using: service(), to: folder) { _ in }
    #expect(try Data(contentsOf: output) == zipFixture)
}
@Test func refusesMismatchedPartialAndExistingOutput() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let firmware = try info()
    let partial = folder.appendingPathComponent(firmware.filename + ".partial")
    try Data([1, 2, 3]).write(to: partial)
    await #expect(throws: FirmwareError.self) { try await Transfer.download(firmware, using: service(), to: folder) { _ in } }
    #expect(try Data(contentsOf: partial) == Data([1, 2, 3]))
    let existing = folder.appendingPathComponent(firmware.outputName)
    try Data("existing".utf8).write(to: existing)
    await #expect(throws: FirmwareError.self) { try await Transfer.download(firmware, using: service(), to: folder) { _ in } }
    #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
}
@Test func rejectsWrongByteRanges() async throws {
    let firmware = try info()
    await #expect(throws: FirmwareError.self) { try await service(badRange: true).chunk(firmware, start: 16, end: 31) }
}
@Test func corruptedPackageFailsVerification() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let corrupt = folder.appendingPathComponent("corrupt.zip")
    try Data("not a ZIP".utf8).write(to: corrupt)
    await #expect(throws: FirmwareError.self) { try await Transfer.verifyZIP(corrupt) }
}
@Test func enc2UsesLegacyKey() throws {
    let device = try Device(model: "SM-S928B", region: "EUX")
    let value = try Firmware.parse(metadata(filename: "legacy.zip.enc2"), device: device, requestedVersion: testVersion)
    #expect(value.key == Crypto.md5("EUX:SM-S928B:\(testVersion)"))
}
@Test func decryptsAcrossChunkBoundary() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    var plaintext = Data(repeating: 0x5a, count: 8 * 1024 * 1024 + 17)
    plaintext.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x03, 0x04])
    let encrypted = try Crypto.aes(plaintext, key: testKey, decrypt: false, padding: true)
    let original = try info()
    let firmware = Firmware(device: original.device, version: original.version, filename: original.filename,
                            path: original.path, size: Int64(encrypted.count), modelType: original.modelType, key: original.key)
    let input = folder.appendingPathComponent("encrypted.enc4")
    let output = folder.appendingPathComponent("decrypted.zip")
    try encrypted.write(to: input)
    try await Transfer.decrypt(firmware, input: input, output: output) { _ in }
    #expect(try Data(contentsOf: output) == plaintext)
}
@Test func cancellationPreservesPartial() async throws {
    let folder = try temporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let firmware = try info()
    let partial = folder.appendingPathComponent(firmware.filename + ".partial")
    try encryptedFixture.prefix(16).write(to: partial)
    try JSONEncoder().encode(firmware).write(to: folder.appendingPathComponent(firmware.filename + ".resume.json"))
    let task = Task {
        try await Transfer.download(firmware, using: service(), to: folder) { _ in
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try Data(contentsOf: partial) == encryptedFixture.prefix(16))
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(firmware.outputName).path))
}
