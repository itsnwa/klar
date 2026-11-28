import Foundation

enum TabAction: Equatable, Identifiable {
    case saveOrMove(isAlreadySaved: Bool, currentParentTitle: String?, isEnabled: Bool)
    case saveToReadingList(isAlreadySaved: Bool, isEnabled: Bool)
    case copyLink(cleanedURL: String, isEnabled: Bool)
    /// Into private browsing or out of it. A saved tab stays, and its page
    /// opens in a new private tab.
    case privateBrowsing(isPrivate: Bool, isSaved: Bool, isEnabled: Bool)
    /// Questions about the page the AI answers from the web (`ExplorePage`).
    /// `reason`: why it can't, when it can't.
    case explore(reason: String?, isEnabled: Bool)

    var id: String {
        switch self {
        case .saveOrMove: return "save-or-move"
        case .saveToReadingList: return "save-to-reading-list"
        case .copyLink: return "copy-link"
        case .privateBrowsing: return "private-browsing"
        case .explore: return "explore"
        }
    }

    var title: String {
        switch self {
        case .saveOrMove(let isAlreadySaved, _, _):
            return isAlreadySaved ? "Move Tab" : "Save Tab..."
        case .saveToReadingList(let isAlreadySaved, _):
            return isAlreadySaved ? "Remove from Reading List" : "Save to Reading List"
        case .copyLink:
            return "Copy Link"
        case .privateBrowsing(let isPrivate, let isSaved, _):
            if isPrivate { return "Reload Outside Private Browsing" }
            return isSaved ? "Open in Private Tab" : "Reload in Private Tab"
        case .explore:
            return "Explore with AI..."
        }
    }

    var subtitle: String? {
        switch self {
        case .saveOrMove(let isAlreadySaved, let currentParentTitle, _):
            guard isAlreadySaved else { return nil }
            return currentParentTitle.map { "in \($0)" } ?? "in Saved"
        case .saveToReadingList(let isAlreadySaved, _):
            return isAlreadySaved ? "Already in Safari Reading List" : nil
        case .copyLink(let cleanedURL, _):
            return cleanedURL.isEmpty ? nil : cleanedURL
        case .privateBrowsing(let isPrivate, _, _):
            return isPrivate ? nil : "Signed out, and kept out of history"
        case .explore(let reason, _):
            return reason ?? "Sites like this, discussions, other sources"
        }
    }

    var systemIcon: String {
        switch self {
        case .saveOrMove(let isAlreadySaved, _, _):
            return isAlreadySaved ? "folder.fill" : "folder.badge.plus.fill"
        case .saveToReadingList(let isAlreadySaved, _):
            return isAlreadySaved ? "eyeglasses.slash" : "eyeglasses"
        case .copyLink:
            return "link"
        case .privateBrowsing(let isPrivate, _, _):
            return isPrivate ? "sunglasses" : "sunglasses.fill"
        case .explore:
            return "sparkles"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .saveOrMove(_, _, let isEnabled): return isEnabled
        case .saveToReadingList(_, let isEnabled): return isEnabled
        case .copyLink(_, let isEnabled): return isEnabled
        case .privateBrowsing(_, _, let isEnabled): return isEnabled
        case .explore(_, let isEnabled): return isEnabled
        }
    }

    /// User-visible keyboard shortcut hint as discrete key labels (e.g. ["⌘", "⇧", "C"]).
    /// Nil for actions without a global shortcut.
    var keyboardShortcut: [String]? {
        switch self {
        case .saveOrMove: return nil
        case .saveToReadingList: return nil
        case .copyLink: return ["⌘", "⇧", "C"]
        case .privateBrowsing: return nil
        case .explore: return nil
        }
    }
}

@MainActor
enum TabActionsBuilder {
    static func actions(for activeTab: BrowserTab?, sidebarManager: SidebarManager?) -> [TabAction] {
        let hasUsableTab: Bool = {
            // A locked private tab's page isn't to be copied, saved or moved
            guard let activeTab = activeTab, !activeTab.isLocked else { return false }
            return !activeTab.url.isEmpty && activeTab.url != "about:blank"
        }()

        let savedInfo = savedTabInfo(for: activeTab, sidebarManager: sidebarManager)
        let saveOrMoveEnabled = hasUsableTab
            && sidebarManager != nil
            && sidebarManager?.isInitializing == false

        let cleanedURL: String = {
            guard let activeTab = activeTab, hasUsableTab else { return "" }
            return URLUtilities.removeTrackingParameters(from: activeTab.url).cleanURL
        }()

        let readingList = SafariReadingListManager.shared
        let isInReadingList: Bool = {
            guard hasUsableTab, let url = activeTab?.url else { return false }
            return readingList.contains(url: url)
        }()
        // Adding needs no Full Disk Access; removing only shows for pages in the list.
        let readingListEnabled = hasUsableTab
            && (isInReadingList || SafariReadingListManager.canAdd(url: activeTab?.url ?? ""))

        return [
            .saveOrMove(
                isAlreadySaved: savedInfo.isSaved,
                currentParentTitle: savedInfo.parentTitle,
                isEnabled: saveOrMoveEnabled
            ),
            .saveToReadingList(
                isAlreadySaved: isInReadingList,
                isEnabled: readingListEnabled
            ),
            .copyLink(cleanedURL: cleanedURL, isEnabled: hasUsableTab),
            .privateBrowsing(
                isPrivate: activeTab?.isPrivate == true,
                isSaved: savedInfo.isSaved,
                isEnabled: hasUsableTab
            ),
            explore(for: activeTab)
        ]
    }

    /// Only for a web page, not a private tab's, and with an AI that can search the web
    private static func explore(for activeTab: BrowserTab?) -> TabAction {
        if activeTab?.isPrivate == true {
            return .explore(reason: "Not in private tabs", isEnabled: false)
        }
        if TOMLSettingsManager.shared.aiProvider == .ollama {
            return .explore(reason: "Needs Claude or Codex in Settings › AI, to search the web", isEnabled: false)
        }
        return .explore(reason: nil, isEnabled: ExplorePage.canAsk(about: activeTab))
    }

    private struct SavedInfo {
        let isSaved: Bool
        let parentTitle: String?
    }

    private static func savedTabInfo(for activeTab: BrowserTab?, sidebarManager: SidebarManager?) -> SavedInfo {
        guard let activeTab = activeTab,
              let sidebarManager = sidebarManager else {
            return SavedInfo(isSaved: false, parentTitle: nil)
        }

        guard let sidebarTabID = sidebarManager.browserToSidebarTabMapping[activeTab.id],
              let sidebarTab = sidebarManager.sidebarStructure.tabs[sidebarTabID] else {
            return SavedInfo(isSaved: false, parentTitle: nil)
        }

        let parentTitle: String? = {
            guard let parentID = sidebarTab.parentID else { return nil }
            return sidebarManager.sidebarStructure.folders[parentID]?.displayTitle
        }()

        return SavedInfo(isSaved: true, parentTitle: parentTitle)
    }
}
