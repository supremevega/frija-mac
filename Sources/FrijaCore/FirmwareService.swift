import Foundation

public actor FirmwareService {
    private let session: URLSession
    private var nonce = ""
    private var signature = ""
    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 180
            self.session = URLSession(configuration: config)
        }
    }
    public static func normalizeVersion(_ version: String) throws -> String {
        var parts = version.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().components(separatedBy: "/")
        guard (3...4).contains(parts.count), parts.allSatisfy({ $0.range(of: "^[A-Z0-9]*$", options: .regularExpression) != nil }),
              !parts[0].isEmpty, !parts[1].isEmpty else {
            throw FirmwareError("Enter the full PDA/CSC/MODEM firmware version, or leave it blank for the latest release.")
        }
        if parts[2].isEmpty { parts[2] = parts[0] }
        if parts.count == 3 { parts.append(parts[0]) }
        guard !parts[3].isEmpty else { throw FirmwareError("The fourth firmware version component is empty.") }
        return parts.joined(separator: "/")
    }
    private func headers() -> [String: String] {
        ["User-Agent": "SMART 2.0",
         "Authorization": "FUS nonce=\"\(nonce)\", signature=\"\(signature)\", nc=\"\", type=\"\", realm=\"\", newauth=\"1\""]
    }
    private func post(_ endpoint: String, body: String = "") async throws -> Data {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://neofussvr.sslcs.cdngc.net/\(endpoint)")!)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers()
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FirmwareError("Invalid Samsung server response.") }
        if let newNonce = response.value(forHTTPHeaderField: "NONCE"), !newNonce.isEmpty {
            nonce = newNonce
            signature = try Crypto.signNonce(newNonce)
        }
        guard response.statusCode == 200 else { throw FirmwareError("Samsung’s firmware service returned HTTP \(response.statusCode). Please try again later.") }
        return data
    }
    private func handshake() async throws {
        _ = try await post("NF_SmartDownloadGenerateNonce.do")
        guard !nonce.isEmpty else { throw FirmwareError("Samsung did not return an authentication nonce.") }
    }
    public func latestVersion(for device: Device) async throws -> String {
        let url = URL(string: "https://fota-cloud-dn.ospserver.net/firmware/\(device.region)/\(device.model)/version.xml")!
        var request = URLRequest(url: url)
        request.setValue("Kies2.0_FUS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FirmwareError("No firmware listing found. Check the model number and CSC.")
        }
        let values = try XMLValues(data)
        guard let version = values["latest"], !version.isEmpty else { throw FirmwareError("Samsung has no latest firmware listed for this model and CSC.") }
        return try Self.normalizeVersion(version)
    }
    public func check(device: Device, version requested: String = "") async throws -> Firmware {
        let version: String
        if requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { version = try await latestVersion(for: device) }
        else { version = try Self.normalizeVersion(requested) }
        try await handshake()
        let body = fusMessage([
            ("CmdID", "1"), ("ACCESS_MODE", "1"), ("BINARY_NATURE", "1"), ("REQUEST_TYPE", "2"),
            ("LOGIC_CHECK", Crypto.logicCheck(version, nonce: nonce)), ("BINARY_SW_VERSION", version),
            ("BINARY_LOCAL_CODE", device.region), ("BINARY_MODEL_NAME", device.model)
        ], getVersion: true)
        return try Firmware.parse(await post("NF_SmartDownloadBinaryInform.do", body: body), device: device, requestedVersion: version)
    }
    public func authorize(_ firmware: Firmware) async throws {
        if nonce.isEmpty { try await handshake() }
        let chars = Array(firmware.filename)
        let input = String(chars[max(0, chars.count - 25)..<max(0, chars.count - 9)])
        let body = fusMessage([
            ("BINARY_NAME", firmware.filename), ("BINARY_SW_VERSION", firmware.version),
            ("DEVICE_LOCAL_CODE", firmware.device.region), ("DEVICE_MODEL_TYPE", firmware.modelType),
            ("LOGIC_CHECK", Crypto.logicCheck(input, nonce: nonce))
        ])
        let values = try XMLValues(await post("NF_SmartDownloadBinaryInitForMass.do", body: body))
        try values.checkStatus()
    }
    public func chunk(_ firmware: Firmware, start: Int64, end: Int64) async throws -> Data {
        guard start >= 0, end >= start, end < firmware.size else { throw FirmwareError("Invalid download range.") }
        // Samsung serves the encrypted binary over HTTP, matching Smart Switch.
        // Only this host is allowed by the app’s ATS exception; metadata/auth use HTTPS.
        let url = URL(string: "http://cloud-neofussvr.samsungmobile.com/NF_SmartDownloadBinaryForMass.do?file=\(firmware.path)\(firmware.filename)")!
        for attempt in 0..<2 {
            var request = URLRequest(url: url)
            request.allHTTPHeaderFields = headers()
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw FirmwareError("Invalid firmware download response.") }
            if http.statusCode == 401 && attempt == 0 {
                try await handshake()
                try await authorize(firmware)
                continue
            }
            let expectedRange = "bytes \(start)-\(end)/\(firmware.size)"
            guard http.statusCode == 206, http.value(forHTTPHeaderField: "Content-Range") == expectedRange,
                  Int64(data.count) == end - start + 1 else {
                throw FirmwareError("Samsung returned an unexpected download range (HTTP \(http.statusCode)). The partial file was preserved.")
            }
            return data
        }
        throw FirmwareError("Download authorization expired. Please retry.")
    }
}
