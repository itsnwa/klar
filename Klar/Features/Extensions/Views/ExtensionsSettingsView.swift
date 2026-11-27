import AppKit
import SwiftUI
import WebKit

/// Settings › Extensions: what's installed (on/off, pin, options,
/// permissions, remove), and the ways to add more — the Chrome Web Store,
/// a store link, other browsers, or an unpacked folder.
struct ExtensionsSettingsView: View {
    @ObservedObject private var manager = ExtensionManager.shared
    @State private var storeLink = ""
    @State private var showsImport = false
    @State private var permissionsItemID: String?

    private var storeLinkID: String? {
        ExtensionInstaller.extensionID(fromLinkOrID: storeLink)
    }

    var body: some View {
        SettingsDetailContainer {
            Section("Installed") {
                if manager.items.isEmpty {
                    Text("No extensions yet. Open an extension's page in the Chrome Web Store and choose Add to Klar.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(manager.items) { item in
                        ExtensionSettingsRow(item: item) { permissionsItemID = item.id }
                    }
                }
            }

            Section("Add Extensions") {
                SettingsRow(
                    title: "Chrome Web Store",
                    subtitle: "Open an extension's page and choose Add to Klar"
                ) {
                    Button("Open Store") { manager.showExtensionPage(ExtensionInstaller.webStoreURL) }
                }
                SettingsRow(title: "Store link", subtitle: "An extension's Chrome Web Store link or ID") {
                    HStack(spacing: 8) {
                        TextField("", text: $storeLink, prompt: Text("chromewebstore.google.com/detail/…"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: 220)
                            .onSubmit(addFromLink)
                        Button("Add", action: addFromLink)
                            .disabled(storeLinkID == nil)
                    }
                }
                SettingsRow(
                    title: "From another browser",
                    subtitle: "What you added from the Chrome Web Store in Chrome, Arc, Dia, Brave or Edge, reinstalled fresh from the store. Nothing else is copied"
                ) {
                    Button("Choose…") { showsImport = true }
                }
            }

            Section("Apps and Password Managers") {
                Text("Extensions that work with a Mac app, like 1Password or Bitwarden, reach it the way they do in Chrome. For 1Password, also add Klar under 1Password › Settings › Browser › Add Browser. While a password manager's extension is on, Klar's own sign-in suggestions step aside.")
                    .foregroundColor(.secondary)
            }

            Section("Developer") {
                SettingsRow(
                    title: "Load unpacked extension",
                    subtitle: "A folder with a manifest.json, read in place. Reload picks up your changes"
                ) {
                    Button("Choose Folder…", action: chooseUnpackedFolder)
                }
            }
        }
        .sheet(isPresented: $showsImport) {
            ExtensionImportSheet { showsImport = false }
        }
        .sheet(item: Binding(
            get: { permissionsItemID.flatMap { id in manager.items.first { $0.id == id } } },
            set: { permissionsItemID = $0?.id }
        )) { item in
            ExtensionPermissionsSheet(item: item) { permissionsItemID = nil }
        }
    }

    private func addFromLink() {
        guard let id = storeLinkID else { return }
        storeLink = ""
        Task { await manager.installFromWebStore(id: id) }
    }

    private func chooseUnpackedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Load"
        panel.message = "Choose the extension's folder (the one with manifest.json)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task { await manager.loadUnpacked(from: folder) }
    }
}

// MARK: - Row

private struct ExtensionSettingsRow: View {
    let item: ExtensionManager.Item
    let showPermissions: () -> Void
    @ObservedObject private var manager = ExtensionManager.shared

    private var subtitle: String {
        if let error = item.error { return error }
        if item.isInstalling { return "Updating…" }
        if let pending = item.record.pendingUpdateVersion {
            return "Version \(pending) wants more access and waits for your approval"
        }
        if item.isPasswordManager && item.record.isEnabled {
            return "Fills your sign-ins instead of Klar while it's on"
        }
        return item.webExtension?.displayDescription ?? ""
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { item.record.isEnabled },
            set: { manager.setEnabled($0, for: item.id) }
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if let icon = item.webExtension?.icon(for: NSSize(width: 32, height: 32)) {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundColor(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            .opacity(item.record.isEnabled ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.body)
                        .lineLimit(1)
                    if let version = item.version {
                        Text(version)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if item.record.source == .unpacked {
                        Text("Unpacked")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(item.error == nil ? .secondary : .red)
                        .lineLimit(2)
                }
            }

            Spacer()

            if item.record.pendingUpdateVersion != nil {
                Button("Update…") {
                    Task { await manager.reviewPendingUpdate(for: item.id) }
                }
                .disabled(item.isInstalling)
            }

            Menu {
                Button(item.record.isPinned ? "Unpin from URL Bar" : "Pin to URL Bar") {
                    manager.setPinned(!item.record.isPinned, for: item.id)
                }
                .disabled(!item.record.isEnabled)
                if item.context?.optionsPageURL != nil {
                    Button("Options") { manager.openOptionsPage(for: item.id) }
                }
                Button("Permissions…", action: showPermissions)
                    .disabled(item.webExtension == nil)
                if item.record.source == .unpacked {
                    Divider()
                    Button("Reload") { Task { await manager.reload(item.id) } }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([item.record.folderURL])
                    }
                } else {
                    Button("View in Chrome Web Store") {
                        if let url = URL(string: "https://\(ExtensionInstaller.webStoreHost)/detail/\(item.id)") {
                            manager.showExtensionPage(url)
                        }
                    }
                }
                Divider()
                Button("Remove…") { Task { await manager.confirmAndRemove(id: item.id) } }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Toggle(item.name, isOn: isEnabled)
                .labelsHidden()
        }
    }
}

// MARK: - Permissions

private struct ExtensionPermissionsSheet: View {
    let item: ExtensionManager.Item
    let onDone: () -> Void

    private var lines: [String] {
        let permissions = Set(item.record.grantedPermissions.keys)
        let patterns = Set(item.record.grantedMatchPatterns.keys.compactMap { try? WKWebExtension.MatchPattern(string: $0) })
        return ExtensionPermissionPrompt.warnings(permissions: permissions, matchPatterns: patterns)
    }

    private var sites: [String] {
        item.record.grantedMatchPatterns.keys.sorted()
    }

    private var unsupported: [String] {
        item.webExtension.map { ExtensionPermissionPrompt.unsupportedPermissions(of: $0, source: item.record.source) } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name).font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("It can").font(.subheadline.weight(.semibold))
                if lines.isEmpty {
                    Text("Nothing that needs your permission").foregroundColor(.secondary)
                } else {
                    ForEach(lines, id: \.self) { Text("• \($0)") }
                }
            }

            if !sites.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sites").font(.subheadline.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(sites, id: \.self) { Text($0).font(.system(.caption, design: .monospaced)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            if !unsupported.isEmpty {
                Text("Not supported in Klar yet: \(unsupported.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Import from other browsers

struct ExtensionImportSheet: View {
    let onDone: () -> Void
    @ObservedObject private var manager = ExtensionManager.shared
    @State private var found: [ExtensionInstaller.ForeignExtension]?
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extensions from Other Browsers").font(.headline)
            Text("Each one is reinstalled fresh from the Chrome Web Store with its signature checked, and you approve each one. Nothing is copied from the other browser, including settings, cookies or sign-ins.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Group {
                if let found {
                    if found.isEmpty {
                        Text("No Chrome Web Store extensions found in Chrome, Arc, Brave, Edge, Vivaldi or Chromium.")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(found) { foreign in
                            let isInstalled = manager.record(for: foreign.id) != nil
                            Toggle(isOn: selection(for: foreign.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(foreign.name)
                                    Text(isInstalled ? "Already in Klar" : foreign.browsers.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .disabled(isInstalled)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 260)

            HStack {
                Spacer()
                Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                Button(selected.count > 1 ? "Add \(selected.count) Extensions" : "Add Extension", action: install)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            let extensions = await Task.detached { ExtensionInstaller.extensionsInOtherBrowsers() }.value
            found = extensions
            selected = Set(extensions.map(\.id).filter { manager.record(for: $0) == nil })
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    /// One at a time, each with its own approval — after this sheet is
    /// gone, since the approval is a sheet too.
    private func install() {
        let ids = (found ?? []).map(\.id).filter(selected.contains)
        onDone()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            for id in ids {
                await ExtensionManager.shared.installFromWebStore(id: id)
            }
        }
    }
}
