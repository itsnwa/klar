import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings › Import: another browser's spaces (with their pinned tabs and
/// folders) and favorites, picked and brought into the sidebar.
struct SidebarImportSheet: View {
    let source: SidebarImportSource
    let onDone: () -> Void
    @ObservedObject private var spaceManager = SpaceManager.shared

    private enum Phase {
        case reading
        case failed(String)
        case ready(ImportedSidebar)
        case imported(SidebarManager.SidebarImportResult)
    }

    @State private var phase = Phase.reading
    @State private var selectedSpaces: Set<String> = []
    @State private var includesFavorites = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from \(source.name)").font(.headline)
            Text(explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            content
                .frame(height: 260)

            HStack {
                if case .imported = phase {
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction)
                } else {
                    switch (source, phase) {
                    case (.arc, _):
                        Button("Choose File…", action: chooseFile)
                    case (.dia, .failed):
                        Button("Try Again") { Task { await read() } }
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Button("Cancel", action: onDone).keyboardShortcut(.cancelAction)
                    Button("Import", action: runImport)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canImport)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            await read()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .reading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready(let sidebar):
            List {
                if !sidebar.favorites.isEmpty {
                    Toggle(isOn: $includesFavorites) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Favorites")
                            Text(count(sidebar.favorites.count, "site") + ", as pinned sites")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                ForEach(sidebar.spaces) { space in
                    Toggle(isOn: selection(for: space.id)) {
                        HStack(spacing: 8) {
                            SpaceIconView(icon: space.icon, name: space.title, size: 10)
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(RoundedRectangle(cornerRadius: 5).fill((space.color ?? .graphite).color))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(space.title)
                                Text(details(of: space))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

        case .imported(let result):
            Text(summary(of: result))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var canImport: Bool {
        guard case .ready(let sidebar) = phase else { return false }
        return !selectedSpaces.isEmpty || (includesFavorites && !sidebar.favorites.isEmpty)
    }

    // MARK: - Reading

    private func read() async {
        switch source {
        case .arc:
            let url = ArcSidebarReader.defaultFileURL
            await read { try ArcSidebarReader.read(from: url) }
        case .dia:
            // The keychain asks first, which waits for an answer
            await read { try DiaSidebarReader.read() }
        }
    }

    private func read(_ reader: @escaping @Sendable () throws -> ImportedSidebar) async {
        phase = .reading
        let outcome = await Task.detached { Result { try reader() } }.value
        switch outcome {
        case .success(let sidebar) where sidebar.spaces.isEmpty && sidebar.favorites.isEmpty:
            phase = .failed("There’s nothing in this \(source.name) sidebar to import.")
        case .success(let sidebar):
            selectedSpaces = Set(sidebar.spaces.filter { $0.tabCount > 0 }.map(\.id))
            includesFavorites = true
            phase = .ready(sidebar)
        case .failure(let error as ArcSidebarReader.ReadError) where error == .notFound:
            phase = .failed("Arc’s sidebar wasn’t found on this Mac. If you copied StorableSidebar.json from Arc’s folder in Application Support on another Mac, choose it.")
        case .failure(let error as DiaSidebarReader.ReadError):
            phase = .failed(error.localizedDescription)
        case .failure(let error):
            logError(.sidebar, "Couldn't read \(source.name)'s sidebar: \(error)")
            phase = .failed(ArcSidebarReader.ReadError.unreadable.localizedDescription)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose Arc’s StorableSidebar.json"
        panel.directoryURL = ArcSidebarReader.defaultFileURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await read { try ArcSidebarReader.read(from: url) } }
    }

    private func runImport() {
        guard case .ready(let sidebar) = phase else { return }
        let sidebarManager = spaceManager.sidebarManager
        let result = sidebarManager.importSidebar(sidebar, spaceIDs: selectedSpaces, includeFavorites: includesFavorites)
        phase = .imported(result)
    }

    // MARK: - Text

    private var explanation: String {
        switch source {
        case .arc:
            return "Your spaces with their pinned tabs and folders, and your favorites as pinned sites. A space goes into the Klar space of the same name, and what’s already there isn’t added again. Today’s tabs, history, passwords and sign-ins aren’t copied."
        case .dia:
            return "Your spaces with their pinned tabs and folders, and their favorites as pinned sites. A space goes into the Klar space of the same name, and what’s already there isn’t added again. Open tabs, history, passwords and sign-ins aren’t copied. Dia keeps its sidebar encrypted, so macOS asks first whether Klar may use Dia’s key."
        }
    }

    private func selection(for id: String) -> Binding<Bool> {
        Binding(
            get: { selectedSpaces.contains(id) },
            set: { isOn in
                if isOn { selectedSpaces.insert(id) } else { selectedSpaces.remove(id) }
            }
        )
    }

    private func details(of space: ImportedSpace) -> String {
        var parts = [count(space.tabCount, "tab")]
        if space.folderCount > 0 {
            parts.append(count(space.folderCount, "folder"))
        }
        if let existing = spaceManager.spaces.first(where: { $0.name.localizedCaseInsensitiveCompare(space.title) == .orderedSame }) {
            parts.append("into “\(existing.name)”")
        } else if space.usesSeparateProfile {
            parts.append("new space with a separate profile")
        }
        return parts.joined(separator: ", ")
    }

    private func summary(of result: SidebarManager.SidebarImportResult) -> String {
        guard !result.isEmpty else { return "Everything you chose is already in Klar." }
        var parts: [String] = []
        if result.newSpaces > 0 { parts.append(count(result.newSpaces, "new space")) }
        if result.tabs > 0 { parts.append(count(result.tabs, "tab")) }
        if result.pinnedSites > 0 { parts.append(count(result.pinnedSites, "pinned site")) }
        return "Added " + ListFormatter.localizedString(byJoining: parts) + "."
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
