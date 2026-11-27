import AppKit

/// Stable identity for a single row in the sidebar. Used as the diffing key
/// for animated layout transitions and for the row-view reuse pool.
enum SidebarRowKey: Hashable {
    case collectionHeader(UUID)
    /// A group: of saved tabs (a `SidebarFolder`), or of regular tabs below
    /// the divider (an `OpenTabGroup`)
    case folder(UUID)
    case tab(UUID)
    /// The active tab, under the closed group it's in: a saved tab, or a
    /// regular tab's page
    case peekTab(tabID: UUID, hostFolderID: UUID)
    case divider
    case newTabButton
    case regularTab(UUID)
    /// Where a drag over the list would land: room made among the rows.
    case dropSlot
}

/// One laid-out row. Position + size are absolute within the rows view's
/// flipped coordinate space (origin at the top-left of the document).
struct SidebarRow {
    let key: SidebarRowKey
    let frame: CGRect
    /// 0 for root-level items, 1 for items inside a folder, etc. The row
    /// view consumes this to compute its leading inset (depth × 12pt).
    let depth: Int
}

/// Geometry constants. Centralised so we can tweak in one place.
enum SidebarLayoutMetrics {
    /// How far the sidebar's content starts and ends from its top and bottom
    /// edges, toward the URL bar and the space bar, at every zoom level.
    /// Scrolled past them, it goes under a separator line at each
    /// (`SidebarScrollView`, `View.sidebarScrollEdgeSeparators()`).
    nonisolated static let contentEdgeInset: CGFloat = 16
    /// How far in from those edges the separator lines are, the content cut
    /// off there: a list's own padding is what's left of `contentEdgeInset`.
    /// The top one 6 pt under the pinned sites.
    nonisolated static let topSeparatorInset: CGFloat = 6
    /// 6 pt above the space bar's buttons, which are 2 pt into the bar
    /// (28 pt, centered in its 32).
    nonisolated static let bottomSeparatorInset: CGFloat = 4
    /// The padding at the top and bottom of a list inside its separators.
    nonisolated static var contentTopInsideSeparator: CGFloat { contentEdgeInset - topSeparatorInset }
    nonisolated static var contentBottomInsideSeparator: CGFloat { contentEdgeInset - bottomSeparatorInset }
    /// How far below the collection header's top its title's capitals
    /// start, centered in the row. The header is the first row, so its
    /// empty top is part of `contentEdgeInset`, and past the top separator.
    static let collectionHeaderTitleTop: CGFloat = {
        let font = NSFont.systemFont(ofSize: 14)
        let baseline = (collectionHeaderHeight - (font.ascender - font.descender)) / 2 + font.ascender
        return (baseline - font.capHeight).rounded()
    }()
    /// Outer horizontal padding around every row from the sidebar's edges.
    static let outerHorizontalPadding: CGFloat = 6
    /// Each nesting level adds this much leading inset to the row's bg + content.
    static let depthIndent: CGFloat = 12
    /// Standard row height for tabs and folders.
    static let standardRowHeight: CGFloat = 38
    /// Row height for the small "WORK" / collection header row.
    static let collectionHeaderHeight: CGFloat = 38
    /// New-tab button row height.
    static let newTabRowHeight: CGFloat = 38
    /// Spacing above the divider (after the saved-tabs section).
    static let spaceAboveDivider: CGFloat = 6
    /// Divider thickness.
    static let dividerHeight: CGFloat = 1
    /// Spacing below the divider.
    static let spaceBelowDivider: CGFloat = 6
    /// Vertical gap between adjacent rows. Original SwiftUI used VStack(spacing: 0).
    static let rowSpacing: CGFloat = 0
    /// Vertical gap between the new-tab button and the first regular tab.
    static let regularTabsTopGap: CGFloat = 6
}

/// Pure layout function: takes the data + UI state, returns the absolute
/// frame for every visible row plus the total content height. No view
/// objects involved — easy to reason about and test.
enum SidebarLayoutEngine {
    struct Input {
        let structure: SidebarStructure
        let expandedFolders: Set<UUID>
        /// The active tab UUID (sidebar tab id OR browser tab id). Drives
        /// peek-node visibility under collapsed folders.
        let activeTabID: UUID?
        /// Browser tabs that aren't mapped to a sidebar (organized) tab.
        let regularTabs: [BrowserTab]
        /// The group each of them is in, by tab ID (`OpenTabStore`): its
        /// row (a `.folder` key) where its first tab is, its tabs under it
        var regularTabGroups: [UUID: UUID] = [:]
        /// Whether the collection-header chevron is currently expanded.
        let collectionExpanded: Bool
        /// The space shown: its collection's saved tabs and folders. The
        /// first collection when nil.
        let spaceID: UUID?
        /// Available width — used only to set each row's frame.width.
        let width: CGFloat
        /// A saved tab, folder or regular tab dragged out of the list: left
        /// out, with everything in it, while it's away.
        var hiddenItemID: UUID? = nil
    }

    struct Output {
        let rows: [SidebarRow]
        let totalHeight: CGFloat
    }

    static func layout(_ input: Input) -> Output {
        var rows: [SidebarRow] = []
        var y = SidebarLayoutMetrics.contentTopInsideSeparator
        let outerPad = SidebarLayoutMetrics.outerHorizontalPadding
        let totalWidth = max(0, input.width)
        let contentWidth = max(0, totalWidth - outerPad * 2)

        // ─── Collection header ───────────────────────────────────────────
        let collection = input.spaceID.flatMap { input.structure.collections[$0] }
            ?? input.structure.orderedCollections.first
        if let collection = collection {
            // Its capitals `contentEdgeInset` from the sidebar's edge: its
            // empty top can start above the list's, cut off at its separator
            y -= SidebarLayoutMetrics.collectionHeaderTitleTop
            rows.append(SidebarRow(
                key: .collectionHeader(collection.id),
                frame: CGRect(x: outerPad, y: y, width: contentWidth, height: SidebarLayoutMetrics.collectionHeaderHeight),
                depth: 0
            ))
            y += SidebarLayoutMetrics.collectionHeaderHeight

            // ─── Organized tabs / folders (recursive) ────────────────────
            if input.collectionExpanded {
                let topLevelItems = input.structure.getCollectionItems(for: collection.id)
                let activeTabID = input.activeTabID.flatMap { $0 == input.hiddenItemID ? nil : $0 }
                appendItems(
                    topLevelItems,
                    structure: input.structure,
                    expandedFolders: input.expandedFolders,
                    activeTabID: activeTabID,
                    activeTabFolders: activeTabID.map { folders(holding: $0, in: input.structure) } ?? [],
                    hiddenItemID: input.hiddenItemID,
                    depth: 0,
                    x: outerPad,
                    width: contentWidth,
                    y: &y,
                    into: &rows
                )
            }
        }

        // ─── Divider (always shown, even when collection is collapsed) ───
        // Extra 8pt inset on each side beyond the outer padding, mirroring
        // the original SwiftUI divider's `padding(.horizontal, 8)` on top of
        // the section padding. Its row covers the spacing above and below
        // its line, drawn in the middle, which shows Close All on hover
        // (`SidebarDividerView`).
        let dividerExtraInset: CGFloat = 8
        let dividerRowHeight = SidebarLayoutMetrics.spaceAboveDivider + SidebarLayoutMetrics.dividerHeight
            + SidebarLayoutMetrics.spaceBelowDivider
        rows.append(SidebarRow(
            key: .divider,
            frame: CGRect(
                x: outerPad + dividerExtraInset,
                y: y,
                width: max(0, contentWidth - dividerExtraInset * 2),
                height: dividerRowHeight
            ),
            depth: 0
        ))
        y += dividerRowHeight

        // ─── New tab button ──────────────────────────────────────────────
        rows.append(SidebarRow(
            key: .newTabButton,
            frame: CGRect(x: outerPad, y: y, width: contentWidth, height: SidebarLayoutMetrics.newTabRowHeight),
            depth: 0
        ))
        y += SidebarLayoutMetrics.newTabRowHeight

        // ─── Regular (unorganized) browser tabs, and their groups ────────
        let groups = input.regularTabGroups
        let regularTabs = input.regularTabs.filter { tab in
            tab.id != input.hiddenItemID && (groups[tab.id].map { $0 != input.hiddenItemID } ?? true)
        }
        if !regularTabs.isEmpty {
            y += SidebarLayoutMetrics.regularTabsTopGap
            var members: [UUID: [UUID]] = [:]
            for tab in regularTabs {
                if let groupID = groups[tab.id] { members[groupID, default: []].append(tab.id) }
            }
            let activeTabID = input.activeTabID.flatMap { $0 == input.hiddenItemID ? nil : $0 }
            var placedGroups: Set<UUID> = []
            func appendRow(_ key: SidebarRowKey, depth: Int) {
                rows.append(SidebarRow(
                    key: key,
                    frame: CGRect(x: outerPad, y: y, width: contentWidth, height: SidebarLayoutMetrics.standardRowHeight),
                    depth: depth
                ))
                y += SidebarLayoutMetrics.standardRowHeight
            }
            for tab in regularTabs {
                guard let groupID = groups[tab.id] else {
                    appendRow(.regularTab(tab.id), depth: 0)
                    continue
                }
                // A group's tabs come together, where its first one is
                guard placedGroups.insert(groupID).inserted else { continue }
                appendRow(.folder(groupID), depth: 0)
                let tabIDs = members[groupID] ?? []
                if input.expandedFolders.contains(groupID) {
                    for id in tabIDs {
                        appendRow(.regularTab(id), depth: 1)
                    }
                } else if let activeTabID, tabIDs.contains(activeTabID) {
                    // Closed with the active tab in it: it peeks out
                    appendRow(.peekTab(tabID: activeTabID, hostFolderID: groupID), depth: 1)
                }
            }
        }

        y += SidebarLayoutMetrics.contentBottomInsideSeparator
        return Output(rows: rows, totalHeight: y)
    }

    /// Recursive helper that lays out a list of (folders + tabs) at a given
    /// depth, expanding folders that are in `expandedFolders` and emitting
    /// a peek-tab row immediately under any collapsed folder that contains
    /// the active tab.
    private static func appendItems(
        _ items: [any SidebarItem],
        structure: SidebarStructure,
        expandedFolders: Set<UUID>,
        activeTabID: UUID?,
        activeTabFolders: Set<UUID>,
        hiddenItemID: UUID?,
        depth: Int,
        x: CGFloat,
        width: CGFloat,
        y: inout CGFloat,
        into rows: inout [SidebarRow]
    ) {
        for item in items where item.id != hiddenItemID {
            if !rows.isEmpty {
                y += SidebarLayoutMetrics.rowSpacing
            }

            if let tab = item as? SidebarTab {
                rows.append(SidebarRow(
                    key: .tab(tab.id),
                    frame: CGRect(x: x, y: y, width: width, height: SidebarLayoutMetrics.standardRowHeight),
                    depth: depth
                ))
                y += SidebarLayoutMetrics.standardRowHeight
            } else if let folder = item as? SidebarFolder {
                rows.append(SidebarRow(
                    key: .folder(folder.id),
                    frame: CGRect(x: x, y: y, width: width, height: SidebarLayoutMetrics.standardRowHeight),
                    depth: depth
                ))
                y += SidebarLayoutMetrics.standardRowHeight

                if expandedFolders.contains(folder.id) {
                    // Recurse into expanded folder.
                    let children: [any SidebarItem] = folder.childrenIds.compactMap { childID in
                        if let tab = structure.tabs[childID] { return tab }
                        if let sub = structure.folders[childID] { return sub }
                        return nil
                    }
                    appendItems(
                        children,
                        structure: structure,
                        expandedFolders: expandedFolders,
                        activeTabID: activeTabID,
                        activeTabFolders: activeTabFolders,
                        hiddenItemID: hiddenItemID,
                        depth: depth + 1,
                        x: x,
                        width: width,
                        y: &y,
                        into: &rows
                    )
                } else if let activeTabID, activeTabFolders.contains(folder.id) {
                    // Folder is collapsed but contains the active tab → emit
                    // a peek row one level deeper so the active tab is still
                    // visible and clickable.
                    y += SidebarLayoutMetrics.rowSpacing
                    rows.append(SidebarRow(
                        key: .peekTab(tabID: activeTabID, hostFolderID: folder.id),
                        frame: CGRect(x: x, y: y, width: width, height: SidebarLayoutMetrics.standardRowHeight),
                        depth: depth + 1
                    ))
                    y += SidebarLayoutMetrics.standardRowHeight
                }
            }
        }
    }

    /// The folders a saved tab is in, from its own up, by `parentID`; a
    /// parent counts only while its `childrenIds` holds the child, as the
    /// layout goes by those.
    private static func folders(holding tabID: UUID, in structure: SidebarStructure) -> Set<UUID> {
        var result: Set<UUID> = []
        var childID = tabID
        var parentID = structure.tabs[tabID]?.parentID
        while let id = parentID, let folder = structure.folders[id],
              folder.childrenIds.contains(childID), result.insert(id).inserted {
            childID = id
            parentID = folder.parentID
        }
        return result
    }
}
