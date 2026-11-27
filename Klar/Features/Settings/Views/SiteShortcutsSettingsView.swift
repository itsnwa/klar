import SwiftUI

/// Settings › Search: the site shortcuts ("yt cats"), one row
/// each, added from presets or by hand, edited in place.
struct SiteShortcutsSettingsView: View {
    @ObservedObject var settingsManager: TOMLSettingsManager

    private enum Editing: Equatable {
        case new
        case existing(id: String)
    }

    @State private var editing: Editing?
    @State private var keyword = ""
    @State private var url = ""

    private enum Field {
        case keyword
        case url
    }

    @FocusState private var focusedField: Field?

    var body: some View {
        Group {
            SettingsRow(
                title: "Site shortcuts",
                subtitle: editing == nil
                    ? "A word before your search sends it to that site: “yt cats”"
                    : "A word, then the site’s search address with %s where the words go"
            ) {
                if editing != nil {
                    HStack {
                        Button("Cancel", action: stopEditing)
                            .keyboardShortcut(.cancelAction)
                        Button("Save", action: save)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSave)
                    }
                } else {
                    addMenu
                }
            }

            if editing == .new {
                editor
            }

            ForEach(settingsManager.siteShortcuts) { shortcut in
                if editing == .existing(id: shortcut.id) {
                    editor
                } else {
                    row(for: shortcut)
                }
            }
        }
    }

    // MARK: - Adding

    private var addMenu: some View {
        Menu("Add") {
            ForEach(availablePresets) { preset in
                Button {
                    add(preset)
                } label: {
                    Text(preset.name)
                    Text(preset.keyword)
                }
            }
            if !availablePresets.isEmpty {
                Divider()
            }
            Button("Custom…") {
                startEditing(.new, keyword: "", url: "")
            }
        }
        .fixedSize()
    }

    /// Presets for sites not already there.
    private var availablePresets: [SiteShortcutPreset] {
        let urls = Set(settingsManager.siteShortcuts.map(\.url))
        return SiteShortcutPreset.all.filter { !urls.contains($0.url) }
    }

    /// Added as is, unless its keyword is taken: then it's for the user to
    /// pick another.
    private func add(_ preset: SiteShortcutPreset) {
        if shortcut(withKeyword: preset.keyword) == nil {
            settingsManager.siteShortcuts.append(preset.shortcut)
        } else {
            startEditing(.new, keyword: "", url: preset.url)
        }
    }

    // MARK: - Rows

    private func row(for shortcut: SiteShortcut) -> some View {
        HStack(spacing: 10) {
            SiteShortcutIcon(shortcut: shortcut, size: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(shortcut.name)
                Text(shortcut.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(shortcut.keyword)
                .font(.system(.callout, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))

            Button {
                startEditing(.existing(id: shortcut.id), keyword: shortcut.keyword, url: shortcut.url)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .disabled(editing != nil)

            Button {
                remove(shortcut)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .disabled(editing != nil)
        }
        .contextMenu {
            Button("Edit") {
                startEditing(.existing(id: shortcut.id), keyword: shortcut.keyword, url: shortcut.url)
            }
            Button("Remove") {
                remove(shortcut)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The form would lay the fields out as labeled rows (the prompt
            // as a read-only label, the address as a link): plain fields,
            // labels hidden, prompts as verbatim text.
            HStack(spacing: 12) {
                TextField(text: $keyword, prompt: Text(verbatim: "yt")) {
                    Text("Keyword")
                }
                .frame(width: 80)
                .focused($focusedField, equals: .keyword)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                TextField(text: $url, prompt: Text(verbatim: "https://www.youtube.com/results?search_query=%s")) {
                    Text("Search address")
                }
                .focused($focusedField, equals: .url)
            }
            .labelsHidden()
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
            .onSubmit {
                if canSave { save() }
            }

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Editing

    private var trimmedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Another shortcut with this keyword than the one being edited.
    private func shortcut(withKeyword keyword: String) -> SiteShortcut? {
        settingsManager.siteShortcuts.first {
            $0.id == keyword.lowercased() && editing != .existing(id: $0.id)
        }
    }

    /// What's keeping it from being saved, once something's typed.
    private var problem: String? {
        if !trimmedKeyword.isEmpty {
            if !SiteShortcut.isValidKeyword(trimmedKeyword) {
                return "A shortcut is one word."
            }
            if let other = shortcut(withKeyword: trimmedKeyword) {
                return "“\(other.keyword)” is already the shortcut for \(other.name)."
            }
        }
        if !trimmedURL.isEmpty && !SiteShortcut.isValidURL(trimmedURL) {
            return trimmedURL.contains(SiteShortcut.placeholder)
                ? "Enter the site’s whole address, starting with https://."
                : "Put %s in the address where the words go."
        }
        return nil
    }

    private var canSave: Bool {
        SiteShortcut.isValidKeyword(trimmedKeyword)
            && SiteShortcut.isValidURL(trimmedURL)
            && shortcut(withKeyword: trimmedKeyword) == nil
    }

    private func startEditing(_ target: Editing, keyword: String, url: String) {
        self.keyword = keyword
        self.url = url
        editing = target
        // Once the editor's row is in the form
        DispatchQueue.main.async {
            focusedField = .keyword
        }
    }

    private func stopEditing() {
        editing = nil
        keyword = ""
        url = ""
    }

    private func save() {
        guard canSave, let editing else { return }
        let shortcut = SiteShortcut(keyword: trimmedKeyword.lowercased(), url: trimmedURL)
        switch editing {
        case .new:
            settingsManager.siteShortcuts.append(shortcut)
        case .existing(let id):
            if let index = settingsManager.siteShortcuts.firstIndex(where: { $0.id == id }) {
                settingsManager.siteShortcuts[index] = shortcut
            }
        }
        stopEditing()
    }

    private func remove(_ shortcut: SiteShortcut) {
        settingsManager.siteShortcuts.removeAll { $0.id == shortcut.id }
    }
}
