import AppKit
import SwiftUI

/// What the setup's screens find and choose (Onboarding): which screens
/// there are, what iCloud has, what other browsers have, and what's added
/// once the browser opens.
@MainActor
@Observable
final class OnboardingSetup {
    enum Step: Hashable {
        case welcome, iCloud, importing, look, ready
    }

    /// What iCloud offers this Mac
    enum ICloud {
        case checking
        /// No account, or a build not signed for iCloud: no screen for it
        case unavailable
        case available
        /// Another Mac keeps Klar in this account's iCloud already
        case hasKlarData
    }

    enum ImportState {
        case choosing, importing, done
    }

    /// A shortcut on the last screen, whose row lights up a moment as it's
    /// pressed there
    struct Shortcut: Hashable {
        let keys: [String]
        let text: String
        /// The key, as typed without modifiers; "1" stands for any of 1–9
        fileprivate let character: String
        fileprivate let modifiers: UInt

        init(_ keys: [String], _ text: String, character: String, modifiers: NSEvent.ModifierFlags) {
            self.keys = keys
            self.text = text
            self.character = character
            self.modifiers = modifiers.rawValue
        }

        static let all = [
            Shortcut(["⌘", "T"], "New tab: search or go to a site", character: "t", modifiers: .command),
            Shortcut(["⌘", "S"], "Show or hide the sidebar", character: "s", modifiers: .command),
            Shortcut(["⇧", "⌘", "O"], "All your spaces at a glance", character: "o", modifiers: [.shift, .command]),
            Shortcut(["⌃", "1–9"], "Switch spaces", character: "1", modifiers: .control),
            Shortcut(["⌘", "D"], "Two pages side by side", character: "d", modifiers: .command),
        ]

        /// The one a key press is
        static func matching(_ event: NSEvent) -> Shortcut? {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option]).rawValue
            guard var character = event.charactersIgnoringModifiers?.lowercased() else { return nil }
            if character.count == 1, ("1"..."9").contains(character) {
                character = "1"
            }
            return all.first { $0.character == character && $0.modifiers == modifiers }
        }
    }

    private(set) var step = Step.welcome
    /// Whether the last move was back, for the way screens slide
    private(set) var wentBack = false

    private(set) var iCloud = ICloud.checking
    /// iCloud's switch
    var syncWithICloud = true
    /// Set Up Without iCloud, on Welcome Back
    private(set) var declinedRestore = false
    /// Restore: the spaces and tabs come from iCloud, so there's no Import
    private(set) var restoresFromICloud = false

    /// Arc's sidebar, when there's something in it
    private(set) var arcSidebar: ImportedSidebar?
    /// Chrome Web Store extensions in other browsers that Klar hasn't got
    private(set) var foreignExtensions: [ExtensionInstaller.ForeignExtension] = []
    private(set) var hasLookedForImports = false
    var importsArc = true
    var importsArcSpaces = true
    var importsArcFavorites = true
    var importsExtensions = true
    /// Dia's sidebar is there; it's read as it's imported, since macOS asks
    /// first whether Klar may use Dia's key
    private(set) var hasDiaSidebar = false
    var importsDia = true
    private(set) var importState = ImportState.choosing
    /// What Arc's import added
    private(set) var arcSummary: String?
    /// What Dia's import added, or why it couldn't
    private(set) var diaSummary: String?

    /// The shortcut just pressed on the last screen
    private(set) var pressedShortcut: Shortcut?

    @ObservationIgnored private weak var session: BrowserWindowSession?
    /// Added once the browser opens, each asking first
    @ObservationIgnored private var extensionsToInstall: [String] = []

    /// The screens in order, as far as what's found allows. The one showing
    /// stays, whatever turns up meanwhile.
    var steps: [Step] {
        var steps: [Step] = [.welcome]
        if iCloud != .unavailable || step == .iCloud {
            steps.append(.iCloud)
        }
        if step == .importing || !restoresFromICloud && (!hasLookedForImports || hasSomethingToImport) {
            steps.append(.importing)
        }
        steps += [.look, .ready]
        return steps
    }

    var hasSomethingToImport: Bool {
        arcSidebar != nil || hasDiaSidebar || !foreignExtensions.isEmpty
    }

    /// Import with nothing chosen is Skip
    var choosesNothingToImport: Bool {
        let arc = arcSidebar != nil && importsArc && (importsArcSpaces && hasArcSpaces || importsArcFavorites && hasArcFavorites)
        let dia = hasDiaSidebar && importsDia
        let extensions = !foreignExtensions.isEmpty && importsExtensions
        return !arc && !dia && !extensions
    }

    var hasArcSpaces: Bool {
        arcSidebar?.spaces.contains { $0.tabCount > 0 } ?? false
    }

    var hasArcFavorites: Bool {
        !(arcSidebar?.favorites.isEmpty ?? true)
    }

    /// From the start, looking into iCloud and the other browsers meanwhile
    func start(in session: BrowserWindowSession) {
        self.session = session
        step = .welcome
        wentBack = false
        iCloud = .checking
        syncWithICloud = true
        declinedRestore = false
        restoresFromICloud = false
        importState = .choosing
        arcSummary = nil
        diaSummary = nil
        pressedShortcut = nil
        extensionsToInstall = []
        Task { await checkICloud() }
        Task { await lookForImports() }
    }

    // MARK: - Moving

    /// The screen's main button, or Return: on, or what the screen's for
    func primaryAction() {
        switch step {
        case .iCloud where welcomesBack:
            restoreFromICloud()
        case .importing:
            switch importState {
            case .choosing: runImport()
            case .importing: break
            case .done: next()
            }
        default:
            next()
        }
    }

    func next() {
        if step == .iCloud {
            applyICloudChoice()
        }
        let steps = self.steps
        guard let index = steps.firstIndex(of: step) else { return }
        guard index + 1 < steps.count else {
            Onboarding.shared.finish()
            return
        }
        wentBack = false
        step = steps[index + 1]
    }

    func back() {
        let steps = self.steps
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        wentBack = true
        step = steps[index - 1]
        // Choosing again
        if step == .iCloud {
            restoresFromICloud = false
        }
    }

    // MARK: - iCloud

    /// Another Mac keeps Klar in iCloud, and setting up without it wasn't
    /// chosen
    var welcomesBack: Bool {
        iCloud == .hasKlarData && !declinedRestore
    }

    private func checkICloud() async {
        switch await CloudSyncManager.shared.hasKlarDataInICloud() {
        case nil: iCloud = .unavailable
        case false?: iCloud = .available
        case true?: iCloud = .hasKlarData
        }
    }

    /// Welcome Back's Restore: sync on, and on past Import
    func restoreFromICloud() {
        restoresFromICloud = true
        syncWithICloud = true
        next()
    }

    func setUpWithoutICloud() {
        declinedRestore = true
        syncWithICloud = false
    }

    private func applyICloudChoice() {
        guard iCloud != .unavailable else { return }
        TOMLSettingsManager.shared.syncWithICloud = syncWithICloud
    }

    // MARK: - Import

    private func lookForImports() async {
        hasLookedForImports = false
        let arcFile = ArcSidebarReader.defaultFileURL
        let sidebar = await Task.detached { try? ArcSidebarReader.read(from: arcFile) }.value
        let extensions = await Task.detached { ExtensionInstaller.extensionsInOtherBrowsers() }.value
        hasDiaSidebar = await Task.detached { DiaSidebarReader.hasSidebar }.value
        if let sidebar, sidebar.spaces.contains(where: { $0.tabCount > 0 }) || !sidebar.favorites.isEmpty {
            arcSidebar = sidebar
        }
        foreignExtensions = extensions.filter { ExtensionManager.shared.record(for: $0.id) == nil }
        hasLookedForImports = true
    }

    /// Arc's and Dia's spaces and favorites go into the sidebar now (Dia's
    /// once macOS has asked for its key); the extensions wait for the
    /// browser, since each asks in a sheet of its own
    func runImport() {
        guard importState == .choosing else { return }
        if choosesNothingToImport {
            next()
            return
        }
        importState = .importing

        if let sidebar = arcSidebar, let session, importsArc {
            let spaceIDs = importsArcSpaces ? Set(sidebar.spaces.filter { $0.tabCount > 0 }.map(\.id)) : []
            let result = session.sidebarManager.importSidebar(sidebar, spaceIDs: spaceIDs, includeFavorites: importsArcFavorites)
            arcSummary = Self.summary(of: result)
        }
        extensionsToInstall = importsExtensions ? foreignExtensions.map(\.id) : []
        let readsDia = hasDiaSidebar && importsDia

        // Dia's waits for the keychain's answer; the dots run at least a
        // moment, so it's seen happening
        Task {
            let started = ContinuousClock.now
            if readsDia {
                await importDia()
            }
            try? await Task.sleep(until: started + .seconds(1.4))
            importState = .done
        }
    }

    private func importDia() async {
        do {
            let sidebar = try await Task.detached { try DiaSidebarReader.read() }.value
            guard let session else { return }
            let spaceIDs = Set(sidebar.spaces.filter { $0.tabCount > 0 }.map(\.id))
            let result = session.sidebarManager.importSidebar(sidebar, spaceIDs: spaceIDs, includeFavorites: true)
            diaSummary = Self.summary(of: result)
        } catch DiaSidebarReader.ReadError.denied {
            diaSummary = "Not imported: Dia’s key wasn’t given"
        } catch {
            logError(.sidebar, "Couldn't import Dia's sidebar: \(error)")
            diaSummary = "Couldn’t read Dia’s sidebar"
        }
    }

    private static func summary(of result: SidebarManager.SidebarImportResult) -> String {
        var parts: [String] = []
        if result.newSpaces > 0 { parts.append(count(result.newSpaces, "space")) }
        if result.tabs > 0 { parts.append(count(result.tabs, "tab")) }
        if result.pinnedSites > 0 { parts.append(count(result.pinnedSites, "pinned site")) }
        return parts.isEmpty
            ? "Already in Klar"
            : "Added " + ListFormatter.localizedString(byJoining: parts)
    }

    /// The browser is open: the extensions chosen are added one by one, each
    /// asking first
    func finish() {
        let ids = extensionsToInstall
        extensionsToInstall = []
        guard !ids.isEmpty else { return }
        Task {
            // Once the window has settled
            try? await Task.sleep(for: .milliseconds(600))
            for id in ids {
                await ExtensionManager.shared.installFromWebStore(id: id)
            }
        }
    }

    // MARK: - Shortcuts

    /// A shortcut pressed on the last screen: its row lights up a moment
    func pressShortcut(_ shortcut: Shortcut) {
        pressedShortcut = shortcut
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            if pressedShortcut == shortcut {
                pressedShortcut = nil
            }
        }
    }

    static func count(_ number: Int, _ noun: String) -> String {
        "\(number) \(noun)\(number == 1 ? "" : "s")"
    }
}
