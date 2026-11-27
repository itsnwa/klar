import SwiftUI

/// Modal dialog for editing a saved tab's bookmarked URL. Mirrors the
/// SwiftUI implementation that previously lived inside `TabItem.swift`
/// on `main` so the AppKit sidebar can re-use the exact same form when
/// the "Edit URL\u{2026}" context-menu item is invoked. The host
/// presents this view via `NSHostingController.presentAsSheet`.
struct EditURLDialog: View {
    let initialURL: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var url: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Saved URL")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save") {
                    onSave(url)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            url = initialURL
        }
    }
}
