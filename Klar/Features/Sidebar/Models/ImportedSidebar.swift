import Foundation

/// A browser whose sidebar Klar imports (Settings › Import, onboarding).
nonisolated enum SidebarImportSource: Identifiable, Sendable {
    case arc
    case dia

    var id: Self { self }

    var name: String {
        switch self {
        case .arc: return "Arc"
        case .dia: return "Dia"
        }
    }
}

/// Another browser's sidebar, as its reader finds it: its spaces with their
/// pinned tabs and folders, and the favorites (which become pinned sites).
nonisolated struct ImportedSidebar: Sendable {
    let source: SidebarImportSource
    var spaces: [ImportedSpace]
    var favorites: [ImportedTab]
}

nonisolated struct ImportedSpace: Identifiable, Sendable {
    let id: String
    var title: String
    var icon: SpaceIcon
    var color: SpaceColor?
    /// On a browser profile other than the default one.
    var usesSeparateProfile: Bool
    /// The pinned tabs and folders, in order.
    var items: [ImportedItem]

    var tabCount: Int {
        items.reduce(0) { $0 + $1.tabCount }
    }

    var folderCount: Int {
        items.reduce(0) { $0 + $1.folderCount }
    }
}

nonisolated struct ImportedTab: Sendable {
    var url: String
    var title: String
    /// The name it was given in the browser's sidebar, if any.
    var customTitle: String?
}

nonisolated enum ImportedItem: Sendable {
    case tab(ImportedTab)
    /// `icon`: the folder's own, if it has one Klar can show.
    case folder(title: String, icon: Icomoji?, items: [ImportedItem])

    var tabCount: Int {
        switch self {
        case .tab: return 1
        case .folder(_, _, let items): return items.reduce(0) { $0 + $1.tabCount }
        }
    }

    var folderCount: Int {
        switch self {
        case .tab: return 0
        case .folder(_, _, let items): return 1 + items.reduce(0) { $0 + $1.folderCount }
        }
    }
}
