import Foundation

enum ProvisioningError: LocalizedError {
    case unsafeHost, invalidResponse, rejected(Int), missingConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .unsafeHost: return "The router must be a private LAN address."
        case .invalidResponse: return "The Jio router returned an unexpected response."
        case .rejected(let code): return "The router rejected the request (HTTP \(code))."
        case .missingConfiguration(let field): return "Provisioning succeeded but \(field) was missing."
        }
    }
}

private struct LocalHTTPResult: Sendable {
    let body: Data
    let statusCode: Int
    let cookie: String?
}

private enum LocalCurl {
    static func get(url: URL, connectIP: String, cookie: String?) throws -> LocalHTTPResult {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "--silent", "--show-error", "--insecure", "--http1.1",
            "--connect-timeout", "10", "--max-time", "15",
            "--resolve", "jiofiber.local.html:8443:\(connectIP)",
            "--include", "--write-out", "\nX-JioJoin-Status: %{http_code}\n",
            "--config", "-"
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        var configuration = "url = \"\(escaped(url.absoluteString))\"\n"
        configuration += "header = \"User-Agent: JioJoinMac/0.1\"\n"
        if let cookie { configuration += "cookie = \"\(escaped(cookie))\"\n" }
        try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8))
        try input.fileHandleForWriting.close()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: NSURLErrorDomain, code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                     "The private Jio router TLS connection failed (transport \(process.terminationStatus))."])
        }

        let marker = Data("\nX-JioJoin-Status: ".utf8)
        guard let markerRange = raw.range(of: marker, options: .backwards),
              let statusText = String(data: raw[markerRange.upperBound...].dropLast(), encoding: .utf8),
              let status = Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ProvisioningError.invalidResponse
        }
        let response = raw[..<markerRange.lowerBound]
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = response.range(of: separator) else { throw ProvisioningError.invalidResponse }
        let headerData = response[..<headerEnd.lowerBound]
        let body = Data(response[headerEnd.upperBound...])
        let headers = String(data: headerData, encoding: .isoLatin1) ?? ""
        let receivedCookie = headers.components(separatedBy: "\r\n").compactMap { line -> String? in
            guard line.lowercased().hasPrefix("set-cookie:") else { return nil }
            return line.dropFirst("set-cookie:".count).split(separator: ";", maxSplits: 1)
                .first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }.first
        return LocalHTTPResult(body: body, statusCode: status, cookie: receivedCookie)
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct SIPProvisioningValue: Equatable {
    let path: [String]
    let name: String
    let value: String
}

struct SIPProvisioningDocument {
    static let schemaVersion = 1
    let values: [SIPProvisioningValue]

    init(data: Data) throws {
        let delegate = SIPXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ProvisioningError.invalidResponse }
        values = delegate.values
    }

    func value(named name: String, pathContaining pathTerms: [String] = []) -> String? {
        let normalizedName = Self.normalized(name)
        let normalizedTerms = pathTerms.map(Self.normalized)
        return values.first { entry in
            guard Self.normalized(entry.name) == normalizedName else { return false }
            let path = entry.path.map(Self.normalized)
            return normalizedTerms.allSatisfy { term in path.contains(where: { $0.contains(term) }) }
        }?.value
    }

    func preferredProxyAddress() -> String? {
        value(named: "address", pathContaining: ["lbo", "pcscf"])
            ?? value(named: "lbo_p-cscf_address")
            ?? values.first(where: {
                Self.normalized($0.name) == "address" &&
                    $0.value.localizedCaseInsensitiveContains("5068")
            })?.value
            ?? value(named: "address")
    }

    private static func normalized(_ value: String) -> String {
        String(value.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private final class SIPXMLParser: NSObject, XMLParserDelegate {
    var values: [SIPProvisioningValue] = []
    private var path: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        var attributes: [String: String] = [:]
        for (name, value) in attributeDict { attributes[name.lowercased()] = value }
        if elementName.caseInsensitiveCompare("characteristic") == .orderedSame {
            path.append(attributes["type"] ?? "characteristic")
        } else if elementName.caseInsensitiveCompare("parm") == .orderedSame,
                  let name = attributes["name"], let value = attributes["value"] {
            values.append(SIPProvisioningValue(path: path, name: name, value: value))
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if elementName.caseInsensitiveCompare("characteristic") == .orderedSame, !path.isEmpty {
            path.removeLast()
        }
    }
}

@MainActor
final class RouterProvisioner: ObservableObject {
    @Published private(set) var otpPending = false
    @Published private(set) var activity = "Not provisioned"
    private var routerHost = ""
    private var alias = ""
    private var mac = ""
    private var cookie: String?

    private static let baseItems: [URLQueryItem] = [
        .init(name: "terminal_sw_version", value: "7.1.2"),
        .init(name: "SMS_port", value: "0"), .init(name: "act_type", value: "volatile"),
        .init(name: "IMSI", value: ""), .init(name: "msisdn", value: ""),
        .init(name: "IMEI", value: ""), .init(name: "vers", value: "0"),
        .init(name: "token", value: ""), .init(name: "rcs_state", value: "0"),
        .init(name: "rcs_version", value: "5.1B"),
        .init(name: "rcs_profile", value: "joyn_blackbird"),
        .init(name: "client_vendor", value: "WITS"),
        .init(name: "default_sms_app", value: "1"),
        .init(name: "default_vvm_app", value: "0"),
        .init(name: "device_type", value: "vvm"),
        .init(name: "client_version", value: "RCSAndrd-5.3"),
        .init(name: "provisioning_version", value: "2.0"),
        .init(name: "nwk_intf", value: "wifi")
    ]

    func requestOTP(router: String, deviceAlias: String) async throws {
        try beginSession(router: router, deviceAlias: deviceAlias)
        var items = Self.baseItems
        items += [
            .init(name: "terminal_vendor", value: alias), .init(name: "terminal_model", value: alias),
            .init(name: "mac_address", value: mac), .init(name: "alias", value: alias),
            .init(name: "op_type", value: "add")
        ]
        let (_, status) = try await request(items: items)
        guard status == 200 else { throw ProvisioningError.rejected(status) }
        otpPending = true
        activity = "OTP requested. Enter the SMS code to authorize this Mac."
    }

    func verify(otp: String) async throws -> SIPCredentials {
        guard otpPending, Int(otp) != nil else { throw ProvisioningError.invalidResponse }
        let (verifyData, verifyStatus) = try await request(items: [.init(name: "OTP", value: otp)])
        guard verifyStatus == 200 else { throw ProvisioningError.rejected(verifyStatus) }
        var data = verifyData
        if data.isEmpty {
            var items = Self.baseItems
            items += [
                .init(name: "terminal_vendor", value: alias), .init(name: "terminal_model", value: alias),
                .init(name: "mac_address", value: mac), .init(name: "alias", value: alias),
                .init(name: "op_type", value: "add")
            ]
            let (refetched, status) = try await request(items: items)
            guard status == 200 else { throw ProvisioningError.rejected(status) }
            data = refetched
        }
        let credentials = try parseCredentials(data)
        try CredentialStore.save(credentials)
        otpPending = false
        activity = "This Mac is authorized. Credentials are stored only in Keychain."
        return credentials
    }

    func refreshCredentials(router: String, deviceAlias: String) async throws -> SIPCredentials {
        try beginSession(router: router, deviceAlias: deviceAlias)
        var items = Self.baseItems
        items += [
            .init(name: "terminal_vendor", value: alias), .init(name: "terminal_model", value: alias),
            .init(name: "mac_address", value: mac), .init(name: "alias", value: alias),
            .init(name: "op_type", value: "add")
        ]
        activity = "Refreshing the authorized SIP configuration…"
        let (data, status) = try await request(items: items)
        guard status == 200 else { throw ProvisioningError.rejected(status) }
        guard !data.isEmpty else {
            activity = "Authorization needs an OTP."
            throw ProvisioningError.invalidResponse
        }
        let credentials = try parseCredentials(data)
        try CredentialStore.save(credentials)
        activity = "Authorized configuration refreshed."
        return credentials
    }

    private func beginSession(router: String, deviceAlias: String) throws {
        guard LocalNetwork.isPrivateIPv4(router) else { throw ProvisioningError.unsafeHost }
        routerHost = router
        alias = deviceAlias
        mac = DeviceIdentity.mac(for: deviceAlias)
        cookie = nil
    }

    private func parseCredentials(_ data: Data) throws -> SIPCredentials {
        let document = try SIPProvisioningDocument(data: data)
        guard let realm = document.value(named: "realm") else { throw ProvisioningError.missingConfiguration("the SIP realm") }
        guard let password = document.value(named: "userpwd") else { throw ProvisioningError.missingConfiguration("the SIP password") }
        guard let publicValue = document.value(named: "public_user_identity") else { throw ProvisioningError.missingConfiguration("the public identity") }
        let publicID = publicValue.hasPrefix("sip:") ? publicValue : "sip:\(publicValue)"
        let authUser = (document.value(named: "username") ??
                        document.value(named: "private_user_identity") ?? "")
            .replacingOccurrences(of: "sip:", with: "", options: [.anchored, .caseInsensitive])
        guard !authUser.isEmpty else { throw ProvisioningError.missingConfiguration("the authentication identity") }
        let address = document.preferredProxyAddress() ?? "jiofiber.local.html:5068"
        var registrar = address.hasPrefix("sip:") ? address : "sip:\(address)"
        if !registrar.contains("transport=") { registrar += ";transport=tls" }
        let uuid = document.value(named: "uuid_value").map { $0.hasPrefix("<") ? $0 : "<\($0)>" }
            ?? DeviceIdentity.instanceID(mac: mac)
        let fallbackPSAP = "+" + publicID.filter(\.isNumber)
        let psap = document.value(named: "psoltid") ?? fallbackPSAP
        let pani = "GPON;PSAPId=\(psap.hasPrefix("+") ? psap : "+" + psap)"
        return SIPCredentials(publicID: publicID, authUser: authUser, password: password,
                              realm: realm, registrar: registrar, instanceID: uuid,
                              pani: pani, deviceAlias: alias)
    }

    private func request(items: [URLQueryItem]) async throws -> (Data, Int) {
        let connectIP: String
        if routerHost == "jiofiber.local.html" {
            guard let gateway = LocalNetwork.gatewayAddress(), LocalNetwork.isPrivateIPv4(gateway) else {
                throw ProvisioningError.unsafeHost
            }
            connectIP = gateway
        } else {
            connectIP = routerHost
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "jiofiber.local.html"
        components.port = 8443
        components.path = "/"
        components.queryItems = items
        guard let url = components.url else { throw ProvisioningError.invalidResponse }
        let priorCookie = cookie
        let result = try await Task.detached {
            try LocalCurl.get(url: url, connectIP: connectIP, cookie: priorCookie)
        }.value
        if let received = result.cookie { cookie = received }
        return (result.body, result.statusCode)
    }
}
