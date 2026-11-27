import SwiftUI

/// Klar's saved passwords: search, reveal and delete. Settings opens it
/// only after Touch ID, so revealing a password doesn't ask again.
struct SavedPasswordsView: View {
    let onDone: () -> Void

    @State private var credentials: [SavedCredential] = []
    @State private var query: String = ""
    @State private var revealedId: UUID?
    @State private var revealedPassword: String?
    @State private var errorMessage: String?
    @State private var pendingDelete: SavedCredential?

    private var filtered: [SavedCredential] {
        guard !query.isEmpty else { return credentials }
        return credentials.filter {
            $0.host.localizedCaseInsensitiveContains(query) ||
            $0.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Your Passwords")
                    .font(.headline)
                Spacer()
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if filtered.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(filtered) { credential in
                        row(for: credential)
                    }
                }
                .listStyle(.inset)
            }

            if let errorMessage {
                Divider()
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 540, height: 440)
        .task { await refresh() }
        .alert("Delete password for \(pendingDelete?.host ?? "")?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let credential = pendingDelete { delete(credential) }
                pendingDelete = nil
            }
        } message: {
            Text("This will permanently remove the saved login from Klar's keychain.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "key.slash")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(query.isEmpty ? "No saved passwords" : "No matches")
                .font(.headline)
            if query.isEmpty {
                Text("Klar will offer to save passwords when you sign in to a website.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for credential: SavedCredential) -> some View {
        HStack(spacing: 12) {
            FaviconView(url: "https://\(credential.host)", size: 28, fallbackText: credential.host)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(credential.host)
                    .font(.system(size: 13, weight: .medium))
                Text(credential.username)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if revealedId == credential.id, let revealedPassword {
                    Text(revealedPassword)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Spacer()

            Button(action: { reveal(credential) }) {
                Image(systemName: revealedId == credential.id ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealedId == credential.id ? "Hide password" : "Reveal password")

            Button(role: .destructive, action: { pendingDelete = credential }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete password")
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func refresh() async {
        do {
            credentials = try await PasswordManager.shared.allCredentials()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reveal(_ credential: SavedCredential) {
        if revealedId == credential.id {
            revealedId = nil
            revealedPassword = nil
            return
        }
        Task { @MainActor in
            do {
                revealedPassword = try await PasswordManager.shared.reveal(credential)
                revealedId = credential.id
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func delete(_ credential: SavedCredential) {
        Task { @MainActor in
            do {
                try await PasswordManager.shared.delete(credential)
                if revealedId == credential.id {
                    revealedId = nil
                    revealedPassword = nil
                }
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
