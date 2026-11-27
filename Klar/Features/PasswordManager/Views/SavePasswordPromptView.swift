import SwiftUI

struct SavePasswordPromptView: View {
    let host: String
    let username: String
    let onSave: () -> Void
    let onNever: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Save password for \(displayHost)?")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            if !username.isEmpty {
                HStack(spacing: 6) {
                    Text(username)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Never") { onNever() }
                    .controlSize(.small)
                Button("Not Now") { onDismiss() }
                    .controlSize(.small)
                Button("Save") { onSave() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var displayHost: String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
