import Foundation

/// A verification code Apple Passwords offers for a page: a TOTP generator
/// saved with a login, or a code that arrived in Messages or Mail.
struct OneTimeCode: Identifiable, Hashable, Sendable {
    /// The code itself. TOTP entries are listed without one; Passwords
    /// generates the current code when it's filled.
    let code: String?
    let username: String?
    let domain: String?
    /// "totp", or where a delivered code came from.
    let source: String

    var isTOTP: Bool { source == "totp" }

    var id: String { [source, domain ?? "", username ?? "", code ?? ""].joined(separator: "|") }

    init(_ entry: [String: Any]) {
        code = entry["code"] as? String
        username = (entry["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        domain = (entry["domain"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        source = entry["source"] as? String ?? ""
    }
}
