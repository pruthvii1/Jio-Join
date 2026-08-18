import Foundation

enum ReliabilityPolicy {
    static let heartbeatInterval: TimeInterval = 10
    static let heartbeatTimeout: TimeInterval = 8
    static let registrationTimeout: TimeInterval = 30
    static let outgoingCallTimeout: TimeInterval = 45
    static let answeredCallTimeout: TimeInterval = 20
    static let incomingCallTimeout: TimeInterval = 90
    static let hangupTimeout: TimeInterval = 10
    static let forcedHangupGrace: TimeInterval = 5

    static func retryDelay(attempt: Int, jitter: Double = 0) -> TimeInterval {
        let steps: [TimeInterval] = [2, 5, 15, 30, 60, 120, 300]
        let base = steps[min(max(attempt, 0), steps.count - 1)]
        return max(1, min(300, base * (1 + min(0.2, max(-0.2, jitter)))))
    }
}

struct DiagnosticEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let category: String
    let event: String
    let message: String
    let code: Int?

    init(timestamp: Date = Date(), category: String, event: String,
         message: String, code: Int? = nil) {
        self.timestamp = timestamp
        self.category = category
        self.event = event
        self.message = DiagnosticSanitizer.sanitize(message)
        self.code = code
    }
}

enum DiagnosticSanitizer {
    static func sanitize(_ input: String) -> String {
        var value = input
        let patterns = [
            #"(?i)(authorization|proxy-authorization)\s*:\s*[^\r\n]+"#,
            #"(?i)(password|passwd|userpwd|otp|token|secret)\s*[=:]\s*[^\s,&;]+"#,
            #"(?i)(name\s*=\s*[\"']?(?:password|passwd|userpwd|otp|token|secret)[\"']?\s+value\s*=\s*[\"'])[^\"']+"#
        ]
        for pattern in patterns {
            value = replacing(pattern, in: value, template: "$1=[REDACTED]")
        }
        value = replacing(#"(?<![A-Za-z0-9])\+?\d[\d ()-]{6,}\d(?![A-Za-z0-9])"#,
                          in: value, template: "[PHONE REDACTED]")
        value = replacing(#"(?i)(sip:)[^@\s>]+@"#, in: value, template: "$1[REDACTED]@")
        return value
    }

    private static func replacing(_ pattern: String, in value: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: template)
    }
}
