import Foundation

/// A login saved in Apple's Passwords app, as Passwords lists it for a
/// website. The password isn't part of it: `ApplePasswordsManager.password(for:)`
/// fetches it when the login is filled.
struct ApplePasswordsLogin: Identifiable, Hashable, Sendable {
    let username: String
    /// Domain the login is saved under, which Passwords also expects back
    /// when asked for the password.
    let site: String
    /// Title the user gave the login in Passwords, if any.
    let customTitle: String?

    var id: String { "\(site)|\(username)" }
}
