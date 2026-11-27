import LocalAuthentication
import SwiftUI

struct PasswordSettingsView: View {
    @StateObject private var settings = TOMLSettingsManager.shared
    @StateObject private var applePasswords = ApplePasswordsManager.shared
    @ObservedObject private var extensions = ExtensionManager.shared
    @ObservedObject private var cloudSync = CloudSyncManager.shared
    @State private var isPairing = false
    @State private var showsSavedPasswords = false
    @State private var contactsDenied = false

    var body: some View {
        SettingsDetailContainer {
            Section("Your Passwords") {
                if let passwordManager = extensions.enabledPasswordManagerName {
                    Text("The “\(passwordManager)” extension is on, so it fills and saves your sign-ins instead of Klar. Verification codes and your contact details still come from Klar.")
                        .foregroundColor(.secondary)
                }
                SettingsRow(
                    title: "Your passwords",
                    subtitle: cloudSync.passwordsInICloud
                        ? "In iCloud Keychain, synced to your Macs, shown with Touch ID"
                        : "In the macOS keychain, shown with Touch ID"
                ) {
                    Button("Open…", action: openSavedPasswords)
                }
                Toggle(isOn: $settings.offerToSavePasswords) {
                    Text("Offer to save passwords")
                    Text("Asked when you sign in; choose Never to stop asking for a site")
                }
                Toggle(isOn: $settings.fillSignIns) {
                    Text("Fill in sign-ins")
                    Text("Click a sign-in box and your accounts for the site hang from it")
                }
                Toggle(isOn: $settings.offerPasskeys) {
                    Text("Offer passkeys")
                    Text("Touch ID or an iCloud passkey, on sites that offer one. Applies to tabs opened afterwards")
                }
            }

            Section("Apple Passwords") {
                Toggle(isOn: $settings.useApplePasswords) {
                    Text("Passwords from Apple's Passwords app")
                    Text("Your Passwords app's accounts and verification codes under sign-in boxes. Unofficial")
                }
                if settings.useApplePasswords {
                    SettingsRow(title: statusTitle, subtitle: statusDescription) {
                        statusControl
                    }
                }
                if isPairing && settings.useApplePasswords {
                    PasswordPairingView(
                        onPaired: { isPairing = false },
                        onCancel: { isPairing = false }
                    )
                    .frame(maxWidth: .infinity)
                }
            }

            Section("Filling in Forms") {
                Toggle(isOn: fillContactDetails) {
                    Text("Fill in your contact details")
                    Text(contactsDenied
                        ? "Klar needs access to Contacts: System Settings › Privacy & Security › Contacts"
                        : "Your card in Contacts under name, email, phone and address boxes")
                }
            }
        }
        .sheet(isPresented: $showsSavedPasswords) {
            SavedPasswordsView { showsSavedPasswords = false }
        }
        .onChange(of: settings.useApplePasswords) { _, enabled in
            if !enabled {
                isPairing = false
                applePasswords.disconnect()
            }
        }
    }

    /// Turning it on asks for Contacts access first and stays off without it.
    private var fillContactDetails: Binding<Bool> {
        Binding(
            get: { settings.fillContactDetails },
            set: { enabled in
                guard enabled else {
                    settings.fillContactDetails = false
                    return
                }
                Task { @MainActor in
                    let granted = await ContactCardProvider.shared.requestAccess()
                    contactsDenied = !granted
                    settings.fillContactDetails = granted
                }
            }
        )
    }

    // MARK: - Apple Passwords status

    private var statusTitle: String {
        switch applePasswords.state {
        case .paired: return "Connected"
        case .connecting: return "Connecting…"
        case .awaitingCode: return "Waiting for the code"
        case .unavailable: return "Unavailable"
        case .idle, .notPaired: return "Not connected"
        }
    }

    private var statusDescription: String {
        switch applePasswords.state {
        case .paired:
            return "The Passwords app's accounts and codes appear under sign-in boxes until Klar quits"
        case .unavailable(let reason):
            return reason
        case .idle, .notPaired, .connecting, .awaitingCode:
            return "Your Mac shows a code, and you type it here. Once per launch of Klar, and only when you first want an account: under a sign-in box, Connect Apple Passwords… asks for it there"
        }
    }

    @ViewBuilder
    private var statusControl: some View {
        switch applePasswords.state {
        case .paired:
            HStack(spacing: 8) {
                Button("Open Passwords") { applePasswords.openPasswordsApp() }
                Button("Disconnect") { applePasswords.disconnect() }
            }
        case .connecting:
            ProgressView().controlSize(.small)
        case _ where isPairing:
            // The code boxes below have no buttons of their own.
            Button("Cancel") { isPairing = false }
        case .unavailable:
            Button("Try Again") { isPairing = true }
        case .idle, .notPaired, .awaitingCode:
            Button("Connect…") { isPairing = true }
        }
    }

    // MARK: - Saved passwords

    private func openSavedPasswords() {
        Task { @MainActor in
            let context = LAContext()
            // Without Touch ID or a login password set up there's nothing to ask.
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
                showsSavedPasswords = true
                return
            }
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "show your saved passwords") {
                    showsSavedPasswords = true
                }
            } catch {
                logDebug(.passwords, "saved passwords authentication cancelled: \(error.localizedDescription)")
            }
        }
    }
}
