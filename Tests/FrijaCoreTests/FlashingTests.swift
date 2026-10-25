import Foundation
import CryptoKit
import Testing
@testable import FrijaCore

private let flashDevice = FlashDevice(model: "SM-F776U", serial: "TEST-ONLY", bootloader: "F776USQU3AZH7", csc: "VZW")
@Test func conversionAllowsCorrespondingPair() throws {
    try FlashPolicy.validate(device: flashDevice, target: "SM-F776U1", mode: .conversion, targetRevision: 3)
}
@Test func standardRejectsDifferentModel() {
    #expect(throws: FirmwareError.self) { try FlashPolicy.validate(device: flashDevice, target: "SM-F776U1", mode: .standard, targetRevision: 3) }
}
@Test func conversionRejectsUnrelatedFamily() {
    #expect(throws: FirmwareError.self) { try FlashPolicy.validate(device: flashDevice, target: "SM-S928U1", mode: .conversion, targetRevision: 3) }
}
@Test func flashRejectsBootloaderDowngrade() {
    #expect(throws: FirmwareError.self) { try FlashPolicy.validate(device: flashDevice, target: "SM-F776U1", mode: .conversion, targetRevision: 2) }
}
@Test func flashRequiresDeviceIdentity() {
    var missing = flashDevice; missing.serial = ""
    #expect(throws: FirmwareError.self) { try FlashPolicy.validate(device: missing, target: "SM-F776U1", mode: .conversion, targetRevision: 3) }
}
@Test func parsesAlphabeticBootloaderRevision() { #expect(FlashPolicy.revision("S928U1UESAAZH7") == 10) }
@Test func helperRunnerDrainsFinalJSONBeforeExit() async throws {
    let json = "{\"event\":\"complete\",\"message\":\"test only\"}"
    let result = try await FlashHelper.execute(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", json]) { _ in }
    #expect(result.exitCode == 0)
    #expect(result.events.last?.event == "complete")
}
@Test func helperChecksumRejectsTampering() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("helper"), manifest = dir.appendingPathComponent("manifest.json")
    let data = Data("original".utf8)
    try data.write(to: file)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    try JSONEncoder().encode(["sha256": hash]).write(to: manifest)
    try await FlashHelper.verify(executable: file, manifest: manifest)
    try Data("modified".utf8).write(to: file)
    await #expect(throws: FirmwareError.self) { try await FlashHelper.verify(executable: file, manifest: manifest) }
}
@Test func flashRequestPreservesLiteralPaths() throws {
    let path = "/tmp/firmware $literal/AP_F776U1_test.tar.md5"
    let request = FlashRequest(targetModel: "sm-f776u1", mode: .conversion, packages: [.init(slot: .AP, path: path)])
    let copy = try JSONDecoder().decode(FlashRequest.self, from: JSONEncoder().encode(request))
    #expect(copy.targetModel == "SM-F776U1")
    #expect(copy.packages[0].path == path)
    #expect(copy.confirmation == nil)
}
