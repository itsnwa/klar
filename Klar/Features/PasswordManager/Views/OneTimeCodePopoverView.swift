import SwiftUI

/// Popover surfaced when the user focuses or clicks the key icon on a
/// detected OTP field. Lists the verification codes the Passwords app
/// offers for the page; selecting one fills it into the focused input.
struct OneTimeCodePopoverView: View {
    let host: String
    let codes: [OneTimeCode]
    let passwordsState: ApplePasswordsManager.State
    let onSelect: (OneTimeCode) -> Void
    let onConnect: () -> Void
    let onOpenPasswords: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch passwordsState {
            case .paired where !codes.isEmpty:
                VStack(alignment: .leading, spacing: 1) {
                    PopoverSectionCaption(title: "Verification Codes")
                    ForEach(codes) { code in
                        PasswordRow(
                            title: title(for: code),
                            subtitle: subtitle(for: code),
                            host: code.domain ?? host
                        ) {
                            onSelect(code)
                        }
                    }
                }
                .padding(6)
            case .paired:
                PopoverMessage(
                    title: "No verification codes for \(PasswordPopoverView.displayHost(host)).",
                    detail: "Set up a code for this login in the Passwords app."
                )
            case .unavailable(let reason):
                PopoverMessage(title: "Passwords isn't available.", detail: reason)
            case .idle, .connecting, .notPaired, .awaitingCode:
                ConnectToPasswordsRow(action: onConnect)
            }

            Divider()

            PopoverFooterButton(label: "Open Passwords…", action: onOpenPasswords)
        }
        .frame(width: PasswordPopoverView.width)
    }

    private func title(for code: OneTimeCode) -> String {
        if code.isTOTP { return code.username ?? "Verification code" }
        return code.code ?? "Verification code"
    }

    private func subtitle(for code: OneTimeCode) -> String? {
        if code.isTOTP { return code.domain.map { "Code for \($0)" } }
        return code.domain.map { "From \($0)" } ?? "From Messages"
    }
}
