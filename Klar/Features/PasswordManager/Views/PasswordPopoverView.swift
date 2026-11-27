import SwiftUI

/// Accounts for the site under a sign-in box: Klar's own first, then the
/// Passwords app's (or an offer to connect it this launch).
struct PasswordPopoverView: View {
    /// This and the verification codes' popover. Wide enough for the offer to
    /// connect Passwords to keep its title and detail on a line each.
    static let width: CGFloat = 252

    let host: String
    let savedCredentials: [SavedCredential]
    let appleLogins: [ApplePasswordsLogin]
    /// nil when Apple Passwords is turned off in Settings.
    let applePasswordsState: ApplePasswordsManager.State?
    let onSelectSaved: (SavedCredential) -> Void
    let onSelectApple: (ApplePasswordsLogin) -> Void
    let onConnectApple: () -> Void
    let onManage: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !savedCredentials.isEmpty {
                VStack(spacing: 1) {
                    ForEach(savedCredentials) { credential in
                        PasswordRow(credential: credential) {
                            onSelectSaved(credential)
                        }
                    }
                }
                .padding(6)
            }

            applePasswordsSection

            if showsEmptyState {
                PopoverMessage(
                    title: "No saved passwords for \(Self.displayHost(host)).",
                    detail: "Sign in and Klar will offer to save the password."
                )
            }

            Divider()

            PopoverFooterButton(label: "Manage Passwords…", action: onManage)
        }
        .frame(width: Self.width)
    }

    @ViewBuilder
    private var applePasswordsSection: some View {
        switch applePasswordsState {
        case .paired where !appleLogins.isEmpty:
            VStack(alignment: .leading, spacing: 1) {
                PopoverSectionCaption(title: "From Passwords")
                ForEach(appleLogins) { login in
                    PasswordRow(login: login) {
                        onSelectApple(login)
                    }
                }
            }
            .padding(6)
        case .idle, .connecting, .notPaired, .awaitingCode:
            ConnectToPasswordsRow(action: onConnectApple)
        case .paired, .unavailable, nil:
            EmptyView()
        }
    }

    private var showsEmptyState: Bool {
        guard savedCredentials.isEmpty else { return false }
        switch applePasswordsState {
        case .paired: return appleLogins.isEmpty
        case .unavailable, nil: return true
        case .idle, .connecting, .notPaired, .awaitingCode: return false
        }
    }

    static func displayHost(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

struct PopoverSectionCaption: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}

struct PopoverMessage: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// Offers to pair with the Passwords app, once per launch, the first time
/// its accounts are wanted.
struct ConnectToPasswordsRow: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    Text("Connect Apple Passwords…")
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Text("Enter the code your Mac shows")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A point less below: the gap above includes the popover's border.
        .padding([.top, .horizontal], 6)
        .padding(.bottom, 5)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }
}

struct PopoverFooterButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Rectangle()
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }
}
