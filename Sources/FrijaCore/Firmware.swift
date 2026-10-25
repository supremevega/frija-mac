import Foundation
import CryptoKit
import CommonCrypto

public struct FirmwareError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Device: Codable, Equatable, Sendable {
    public let model: String
    public let region: String
    public init(model: String, region: String) throws {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let region = region.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard model.range(of: "^[A-Z0-9][A-Z0-9-]{2,29}$", options: .regularExpression) != nil else {
            throw FirmwareError("Enter a Samsung model number, such as SM-S928B.")
        }
        guard region.range(of: "^[A-Z0-9]{3}$", options: .regularExpression) != nil else {
            throw FirmwareError("Enter a three-character CSC, such as EUX, XAA, or BTU.")
        }
        self.model = model
        self.region = region
    }
}

public struct Firmware: Codable, Equatable, Sendable {
    public let device: Device
    public let version: String
    public let filename: String
    public let path: String
    public let size: Int64
    public let modelType: String
    public let key: Data
    public var outputName: String {
        if filename.hasSuffix(".enc4") || filename.hasSuffix(".enc2") { return String(filename.dropLast(5)) }
        return filename
    }
    public var isEncrypted: Bool { filename.hasSuffix(".enc4") || filename.hasSuffix(".enc2") }
    public var pda: String { version.components(separatedBy: "/").first ?? version }
    public var csc: String { version.components(separatedBy: "/").dropFirst().first ?? "—" }
    public var modem: String { version.components(separatedBy: "/").dropFirst(2).first ?? "—" }
    public var displaySize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    public static func parse(_ data: Data, device: Device, requestedVersion: String) throws -> Self {
        let xml = try XMLValues(data)
        try xml.checkStatus()
        func required(_ name: String) throws -> String {
            guard let value = xml[name], !value.isEmpty else { throw FirmwareError("Samsung’s response is missing \(name).") }
            return value
        }
        let filename = try required("BINARY_NAME")
        let path = try required("MODEL_PATH")
        let version = xml["BINARY_SW_VERSION"] ?? xml["LATEST_FW_VERSION"] ?? requestedVersion
        guard filename.range(of: "^[A-Za-z0-9_.-]+\\.zip(?:\\.enc[24])?$", options: .regularExpression) != nil,
              !filename.contains(".."), path.range(of: "^[A-Za-z0-9_./-]+$", options: .regularExpression) != nil,
              !path.contains(".."), let size = Int64(try required("BINARY_BYTE_SIZE")), size > 0 else {
            throw FirmwareError("Samsung returned an invalid firmware filename, path, or size.")
        }
        if let model = xml["BINARY_MODEL_NAME"], !model.isEmpty, model.uppercased() != device.model {
            throw FirmwareError("Samsung returned firmware for a different device model.")
        }
        if let region = xml["BINARY_LOCAL_CODE"], !region.isEmpty, region.uppercased() != device.region {
            throw FirmwareError("Samsung returned firmware for a different CSC.")
        }
        let key: Data
        if filename.hasSuffix(".enc2") {
            key = Crypto.md5("\(device.region):\(device.model):\(version)")
        } else if filename.hasSuffix(".enc4") {
            guard size % 16 == 0 else { throw FirmwareError("Encrypted firmware size is not aligned to AES blocks.") }
            guard let logic = xml["LOGIC_VALUE_FACTORY"] ?? xml["LOGIC_VALUE_HOME"], !logic.isEmpty else {
                throw FirmwareError("Samsung did not provide the firmware decryption information.")
            }
            key = Crypto.md5(Crypto.logicCheck(version, nonce: logic))
        } else { key = Data() }
        return Firmware(device: device, version: version, filename: filename, path: path, size: size,
                        modelType: xml["DEVICE_MODEL_TYPE"] ?? "", key: key)
    }
}

// Protocol adaptation: GNSF (MIT), Vladislav Tislenko, 2025–2026;
// samloader-rs (Apache-2.0), John "topjohnwu" Wu, 2026. See Licenses/ and NOTICE.
public enum Crypto {
    public static func md5(_ value: String) -> Data { Data(Insecure.MD5.hash(data: Data(value.utf8))) }
    public static func logicCheck(_ input: String, nonce: String) -> String {
        let chars = Array(input)
        return String(nonce.unicodeScalars.map { scalar in
            let index = Int(scalar.value & 15)
            return index < chars.count ? chars[index] : "."
        })
    }
    public static func signNonce(_ nonce: String) throws -> String {
        let key = Data([0x42, 0x2e, 0x73, 0x73, 0x36, 0x17, 0xae, 0x2b, 0x19, 0x89, 0x40, 0xfd, 0x4e, 0x32, 0xb0, 0xa5])
        var block = Data(nonce.utf8.prefix(16))
        block.append(contentsOf: repeatElement(UInt8(48), count: 16 - block.count))
        return try aes(block, key: key, decrypt: false).map { String(format: "%02x", $0) }.joined()
    }
    public static func aes(_ data: Data, key: Data, decrypt: Bool, padding: Bool = false) throws -> Data {
        guard key.count == 16, data.count % 16 == 0 || (!decrypt && padding) else {
            throw FirmwareError("Invalid AES key or block size.")
        }
        let capacity = data.count + 16
        var output = Data(count: capacity)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { source in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | (padding ? kCCOptionPKCS7Padding : 0)),
                            keyBytes.baseAddress, key.count, nil, source.baseAddress, data.count,
                            out.baseAddress, capacity, &written)
                }
            }
        }
        guard status == kCCSuccess else { throw FirmwareError("Firmware decryption failed (AES \(status)).") }
        output.count = written
        return output
    }
}

final class XMLValues: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var text = ""
    private var values: [String: String] = [:]
    subscript(_ key: String) -> String? { values[key] }
    init(_ data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw FirmwareError("Samsung returned an unreadable XML response.") }
    }
    func checkStatus() throws {
        guard let status = self["Status"], ["200", "S00"].contains(status) else {
            throw FirmwareError("Samsung returned status \(self["Status"] ?? "unknown"). Firmware may be unavailable for this model, CSC, or version.")
        }
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(elementName)
        text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "Data", stack.count >= 2 { values[stack[stack.count - 2]] = value }
        else if ["Status", "latest"].contains(elementName) { values[elementName] = value }
        stack.removeLast()
        text = ""
    }
}

func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func fusMessage(_ fields: [(String, String)], getVersion: Bool = false) -> String {
    let put = fields.map { name, value in
        name == "CmdID" ? "<CmdID>\(xmlEscape(value))</CmdID>" : "<\(name)><Data>\(xmlEscape(value))</Data></\(name)>"
    }.joined()
    return "<FUSMsg><FUSHdr><ProtoVer>1.0</ProtoVer><SessionID>0</SessionID><MsgID>1</MsgID></FUSHdr><FUSBody><Put>\(put)</Put>\(getVersion ? "<Get><CmdID>2</CmdID><BINARY_SW_VERSION/></Get>" : "")</FUSBody></FUSMsg>"
}
