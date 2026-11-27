import SwiftUI

struct PasswordRow: View {
    let title: String
    let subtitle: String?
    /// Host whose favicon leads the row.
    let host: String
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                FaviconView(url: "https://\(host)", size: 28, fallbackText: host)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
        .onHover { hovering in
            if isHovering != hovering { isHovering = hovering }
        }
    }
}

extension PasswordRow {
    /// Username over host for a login in Klar's store.
    init(credential: SavedCredential, onSelect: @escaping () -> Void) {
        let username = credential.username.isEmpty ? nil : credential.username
        self.init(title: username ?? credential.host, subtitle: username == nil ? nil : credential.host,
                  host: credential.host, onSelect: onSelect)
    }

    /// For a login from the Passwords app: custom title over username when
    /// it has one, otherwise username over site.
    init(login: ApplePasswordsLogin, onSelect: @escaping () -> Void) {
        let username = login.username.isEmpty ? nil : login.username
        if let customTitle = login.customTitle, !customTitle.isEmpty {
            self.init(title: customTitle, subtitle: username ?? login.site, host: login.site, onSelect: onSelect)
        } else {
            self.init(title: username ?? login.site, subtitle: username == nil ? nil : login.site,
                      host: login.site, onSelect: onSelect)
        }
    }
}
