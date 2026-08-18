import Foundation

enum CallDirection: String, Codable, CaseIterable {
    case incoming
    case outgoing

    var title: String { self == .incoming ? "Incoming" : "Outgoing" }
    var symbol: String { self == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right" }
}

enum CallOutcome: String, Codable, CaseIterable {
    case completed
    case missed
    case declined
    case failed

    var title: String {
        switch self {
        case .completed: return "Completed"
        case .missed: return "Missed"
        case .declined: return "Declined"
        case .failed: return "Not connected"
        }
    }
}

struct CallRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let remoteParty: String
    let direction: CallDirection
    let startedAt: Date
    let connectedAt: Date?
    let endedAt: Date
    let outcome: CallOutcome

    var duration: TimeInterval {
        guard let connectedAt else { return 0 }
        return max(0, endedAt.timeIntervalSince(connectedAt))
    }
}

struct ActiveCall: Equatable, Identifiable {
    let id: UUID
    let remoteParty: String
    let direction: CallDirection
    let startedAt: Date
    var connectedAt: Date?
}

enum CallerDisplay {
    static func clean(_ value: String) -> String {
        if let sipRange = value.range(of: "sip:", options: .caseInsensitive) {
            let suffix = value[sipRange.upperBound...]
            let address = suffix.prefix { $0 != "@" && $0 != ">" && $0 != ";" }
            if !address.isEmpty { return String(address) }
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"<> "))
    }
}

enum CallHistoryStorage {
    private static let key = "JioJoinMacCallHistoryV1"
    private static let limit = 500

    static func load(defaults: UserDefaults = .standard) -> [CallRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([CallRecord].self, from: data) else { return [] }
        return records
    }

    static func save(_ records: [CallRecord], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Array(records.prefix(limit))) else { return }
        defaults.set(data, forKey: key)
    }
}

enum MissedCallBadgeStorage {
    private static let key = "JioJoinMacHasUnreadMissedCall"

    static func load(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func save(_ hasUnreadMissedCall: Bool, defaults: UserDefaults = .standard) {
        defaults.set(hasUnreadMissedCall, forKey: key)
    }
}

struct SIPCredentials: Codable, Equatable {
    let publicID: String
    let authUser: String
    let password: String
    let realm: String
    let registrar: String
    let instanceID: String
    let pani: String
    let deviceAlias: String
}

enum DeviceIdentity {
    static func hash(_ value: String) -> UInt32 {
        value.utf8.reduce(0) { partial, byte in partial &* 33 &+ UInt32(byte) }
    }

    static func mac(for alias: String) -> String {
        let value = hash(alias)
        let bytes = [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)
        ]
        return ([0, 0] + bytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    static func instanceID(mac: String) -> String {
        let hex = mac.replacingOccurrences(of: ":", with: "").uppercased()
        return "<00000000-0000-1000-8000-\(hex)>"
    }

    static func defaultAlias() -> String {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "JioJoinMacDeviceAlias") { return saved }
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let alias = "JioJoinMac-\(suffix)"
        defaults.set(alias, forKey: "JioJoinMacDeviceAlias")
        return alias
    }
}

enum DialPlan {
    static func normalize(_ raw: String) -> String? {
        let cleaned = raw.filter { $0.isNumber || $0 == "+" }
        guard !cleaned.isEmpty, cleaned.dropFirst().allSatisfy(\.isNumber) else { return nil }
        if cleaned.hasPrefix("+91"), cleaned.count == 13 { return "0" + cleaned.dropFirst(3) }
        if cleaned.count == 10, let first = cleaned.first, "6789".contains(first) { return "0" + cleaned }
        if cleaned.hasPrefix("+") { return String(cleaned.dropFirst()) }
        return cleaned
    }
}

enum LocalNetwork {
    static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return host == "jiofiber.local.html" }
        return parts[0] == 10 ||
            (parts[0] == 172 && (16...31).contains(parts[1])) ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 169 && parts[1] == 254)
    }

    static func command(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultGateway() -> String {
        // Use the router's service name by default so TLS SNI and Host match.
        // The setup UI still accepts an RFC1918 address if local DNS is overridden.
        return "jiofiber.local.html"
    }

    static func gatewayAddress() -> String? {
        let text = command("/sbin/route", ["-n", "get", "default"]) ?? ""
        for line in text.split(separator: "\n") {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == "gateway" {
                return pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func localAddress() -> String {
        let text = command("/sbin/route", ["-n", "get", "default"]) ?? ""
        var interface: String?
        for line in text.split(separator: "\n") {
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].trimmingCharacters(in: .whitespaces) == "interface" {
                interface = pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        guard let interface else { return "" }
        return command("/usr/sbin/ipconfig", ["getifaddr", interface]) ?? ""
    }
}
