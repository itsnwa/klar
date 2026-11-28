import SwiftUI
import UniformTypeIdentifiers

/// Settings › Links: where links opened from other apps go (`LinkRouter`):
/// the space no route matches sends them to, switching to a tab already
/// at the page, and the routes, in order, edited in place.
struct LinksSettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared
    @ObservedObject private var spaceManager = SpaceManager.shared

    var body: some View {
        SettingsDetailContainer {
            Section {
                Picker(selection: $settingsManager.linkDefaultSpaceID) {
                    Text("Space in Front").tag(UUID?.none)
                    Divider()
                    ForEach(spaceManager.spaces) { space in
                        Text(space.name).tag(UUID?.some(space.id))
                    }
                } label: {
                    Text("Open links in")
                    Text("Where a link from another app opens when no route below matches it")
                }

                Toggle(isOn: $settingsManager.reuseOpenTabsForLinks) {
                    Text("Switch to a tab already open")
                    Text("When the page is open in the space the link goes to, or as a pinned site, that tab is shown instead of a new one")
                }
            } header: {
                Text("Links from Other Apps")
            }

            Section {
                LinkRoutesSettingsView(settingsManager: settingsManager, spaceManager: spaceManager)
            } header: {
                Text("Routes")
            } footer: {
                Text("A link from another app opens in the space of the first route it matches. Links that redirect, such as Slack’s, Google’s and Outlook’s, are matched by where they lead.")
            }
        }
    }
}

/// The routes, one row each, with Add, and the route being added or
/// changed as an editor in its place.
private struct LinkRoutesSettingsView: View {
    @ObservedObject var settingsManager: TOMLSettingsManager
    @ObservedObject var spaceManager: SpaceManager

    private enum Editing: Equatable {
        case new
        case existing(id: UUID)
    }

    @State private var editing: Editing?
    @State private var draft = LinkRoute(match: .domain, pattern: "", app: nil, spaceID: UUID())
    @FocusState private var isPatternFocused: Bool

    var body: some View {
        Group {
            SettingsRow(
                title: "Routes",
                subtitle: editing == nil
                    ? "Send a site, or links from an app, to a space"
                    : "What the link matches, the app it comes from, and its space"
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
                    Button("Add Route…") {
                        startEditing(.new, LinkRoute(
                            match: .domain, pattern: "", app: nil,
                            spaceID: spaceManager.spaces.first?.id ?? UUID()
                        ))
                    }
                    .disabled(spaceManager.spaces.isEmpty)
                }
            }

            if editing == .new {
                editor
            }

            ForEach(Array(settingsManager.linkRoutes.enumerated()), id: \.element.id) { index, route in
                if editing == .existing(id: route.id) {
                    editor
                } else {
                    row(for: route, at: index)
                }
            }
        }
    }

    // MARK: - Rows

    private func row(for route: LinkRoute, at index: Int) -> some View {
        let space = spaceManager.space(withID: route.spaceID)
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill((space?.color.color ?? .gray).opacity(0.18))
                if let space {
                    SpaceIconView(icon: space.icon, name: space.name, size: 12)
                        .foregroundStyle(space.color.color)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.summary(of: route))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let app = route.app {
                        AppIcon(bundleID: app, size: 12)
                        Text("From \(AppIdentity.name(of: app))")
                    } else {
                        Text("From any app")
                    }
                    Text(verbatim: "→")
                    if let space {
                        Text(space.name)
                    } else {
                        Text("A space not on this Mac")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            Button {
                startEditing(.existing(id: route.id), route)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            .disabled(editing != nil)

            Button {
                remove(route)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove")
            .disabled(editing != nil)
        }
        .contextMenu {
            Button("Edit") {
                startEditing(.existing(id: route.id), route)
            }
            Divider()
            Button("Move Up") {
                move(from: index, by: -1)
            }
            .disabled(index == 0)
            Button("Move Down") {
                move(from: index, by: 1)
            }
            .disabled(index == settingsManager.linkRoutes.count - 1)
            Divider()
            Button("Remove") {
                remove(route)
            }
        }
    }

    /// What a route matches, as its row's title.
    private static func summary(of route: LinkRoute) -> String {
        let pattern = route.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return "Any link" }
        switch route.match {
        case .domain: return LinkRoute.domain(from: pattern) ?? pattern
        default: return "\(route.match.title) “\(pattern)”"
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(selection: $draft.match) {
                    ForEach(LinkRoute.Match.allCases, id: \.self) { match in
                        Text(match.title).tag(match)
                    }
                } label: {
                    Text("Match")
                }
                .fixedSize()

                TextField(text: $draft.pattern, prompt: Text(verbatim: draft.match.placeholder)) {
                    Text("Pattern")
                }
                .textFieldStyle(.roundedBorder)
                .font(draft.match == .regex ? .system(.body, design: .monospaced) : .body)
                .focused($isPatternFocused)
                .onSubmit {
                    if canSave { save() }
                }
            }

            HStack(spacing: 8) {
                Text("From")
                    .foregroundStyle(.secondary)
                appMenu
                Spacer(minLength: 12)
                Text("Open in")
                    .foregroundStyle(.secondary)
                Picker(selection: $draft.spaceID) {
                    if spaceManager.space(withID: draft.spaceID) == nil {
                        Text("Choose a Space").tag(draft.spaceID)
                    }
                    ForEach(spaceManager.spaces) { space in
                        Text(space.name).tag(space.id)
                    }
                } label: {
                    Text("Space")
                }
                .fixedSize()
            }
            .labelsHidden()

            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .labelsHidden()
        .padding(.vertical, 4)
    }

    /// Any app, the apps that sent links lately, the route's own, or one
    /// chosen from Applications.
    private var appMenu: some View {
        Menu {
            Button("Any App") {
                draft.app = nil
            }
            let apps = menuApps
            if !apps.isEmpty {
                Section("Sent Links Lately") {
                    ForEach(apps, id: \.self) { app in
                        Button {
                            draft.app = app
                        } label: {
                            Label {
                                Text(AppIdentity.name(of: app))
                            } icon: {
                                if let icon = AppIdentity.menuIcon(of: app) {
                                    Image(nsImage: icon)
                                }
                            }
                            // Menus built with the macOS 27 SDK leave out
                            // an item's image unless it asks for it
                            .labelStyle(.titleAndIcon)
                        }
                    }
                }
            }
            Divider()
            Button("Choose App…", action: chooseApp)
        } label: {
            if let app = draft.app {
                Text(AppIdentity.name(of: app))
            } else {
                Text("Any App")
            }
        }
        .fixedSize()
    }

    private var menuApps: [String] {
        var apps = LinkRouter.shared.recentSourceApps.filter { AppIdentity.isInstalled($0) }
        if let app = draft.app, !apps.contains(app) {
            apps.insert(app, at: 0)
        }
        return apps
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the app whose links this route is for"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        draft.app = bundleID
    }

    // MARK: - Editing

    /// What's keeping it from being saved, once something's typed.
    private var problem: String? {
        let pattern = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern.isEmpty {
            return draft.app.map { "Every link from \(AppIdentity.name(of: $0)) opens in this space." }
        }
        switch draft.match {
        case .domain:
            guard let domain = LinkRoute.domain(from: pattern) else {
                return "Enter a domain, such as github.com. Its subdomains match too."
            }
            return "\(domain) and its subdomains."
        case .regex where LinkRoute.regularExpression(pattern) == nil:
            return "This isn’t a regular expression that can be used."
        case .regex:
            return "Matched against the whole address, ignoring case."
        default:
            return nil
        }
    }

    private var canSave: Bool {
        draft.isValid && spaceManager.space(withID: draft.spaceID) != nil
    }

    private func startEditing(_ target: Editing, _ route: LinkRoute) {
        draft = route
        editing = target
        // Once the editor's row is in the form
        DispatchQueue.main.async {
            isPatternFocused = true
        }
    }

    private func stopEditing() {
        editing = nil
    }

    private func save() {
        guard canSave, let editing else { return }
        var route = draft
        route.pattern = route.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if route.match == .domain, let domain = LinkRoute.domain(from: route.pattern) {
            route.pattern = domain
        }
        switch editing {
        case .new:
            route.id = UUID()
            settingsManager.linkRoutes.append(route)
        case .existing(let id):
            if let index = settingsManager.linkRoutes.firstIndex(where: { $0.id == id }) {
                settingsManager.linkRoutes[index] = route
            }
        }
        stopEditing()
    }

    private func remove(_ route: LinkRoute) {
        settingsManager.linkRoutes.removeAll { $0.id == route.id }
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard settingsManager.linkRoutes.indices.contains(index),
              settingsManager.linkRoutes.indices.contains(target) else { return }
        settingsManager.linkRoutes.swapAt(index, target)
    }
}

/// An app's name and icon by its bundle identifier, as installed here.
private enum AppIdentity {
    static func url(of bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        url(of: bundleID) != nil
    }

    /// Its name as Finder shows it, else the identifier itself.
    static func name(of bundleID: String) -> String {
        guard let url = url(of: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Its icon at a menu item's size: a menu draws an image at the size
    /// it has, not the item's.
    static func menuIcon(of bundleID: String) -> NSImage? {
        guard let url = url(of: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage
        icon?.size = NSSize(width: 16, height: 16)
        return icon
    }
}

private struct AppIcon: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        if let url = AppIdentity.url(of: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: size, height: size)
        }
    }
}
