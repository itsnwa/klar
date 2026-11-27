import AppKit

/// Changes to the saved tabs made in one go (Clean Up Saved Tabs…),
/// with Undo in the window's toast. Undo puts the sidebar back as it was,
/// as long as nothing has been moved, added or removed since; tabs keep the
/// titles and state their pages have given them meanwhile.
extension SidebarManager {
    /// Runs `change` (which saves the sidebar in one change), then offers
    /// to undo it. Returns whether it did: not when the sidebar's the same.
    @discardableResult
    func changeUndoably(_ message: String, _ change: () -> Void) -> Bool {
        let before = sidebarStructure
        change()
        let after = sidebarStructure
        guard after.shape != before.shape else { return false }

        tabManager?.toastManager.showToast(
            message: message,
            type: .success,
            action: ToastAction(title: "Undo") { [weak self] in
                self?.restore(before, ifStillShaped: after.shape)
            },
            duration: 8
        )
        return true
    }

    private func restore(_ before: SidebarStructure, ifStillShaped shape: SidebarStructure.Shape) {
        let current = sidebarStructure
        guard current.shape == shape else {
            tabManager?.toastManager.showToast(message: "Couldn’t undo", description: "The sidebar has changed since.", type: .error)
            return
        }

        var restored = before
        for (id, tab) in current.tabs {
            guard let earlier = restored.tabs[id] else { continue }
            var kept = tab
            kept.parentID = earlier.parentID
            kept.customTitle = earlier.customTitle
            kept.collectionID = earlier.collectionID
            kept.order = earlier.order
            restored.tabs[id] = kept
        }
        // Removed ones come back without a page: theirs stayed open as
        // regular tabs, or closed
        for id in restored.tabs.keys where current.tabs[id] == nil {
            restored.tabs[id]?.isUnloaded = true
        }
        // Ones the change added (an open tab pinned or saved) go as removed
        // ones do, their pages staying open as regular tabs; the rest is
        // put back in the same save
        let added = current.tabs.keys.filter { restored.tabs[$0] == nil }
        removeTabs(withIDs: added) { structure in
            structure = restored
        }
        logInfo(.sidebar, "Undid a sidebar change")
    }
}

nonisolated extension SidebarStructure {
    /// What's where, and what it's called by hand: what Undo checks hasn't
    /// changed since. Not pages' own titles or state, which change by
    /// themselves.
    struct Shape: Equatable {
        var tabs: [UUID: Placement]
        var folders: [UUID: [UUID]]
        var rootItems: [UUID]
        var pinnedItems: [UUID]
        var spaces: Set<UUID>

        struct Placement: Equatable {
            var parentID: UUID?
            var collectionID: UUID?
            var customTitle: String?
        }
    }

    var shape: Shape {
        Shape(
            tabs: tabs.mapValues { Shape.Placement(parentID: $0.parentID, collectionID: $0.collectionID, customTitle: $0.customTitle) },
            folders: folders.mapValues(\.childrenIds),
            rootItems: rootItems,
            pinnedItems: pinnedItems,
            spaces: Set(collections.keys)
        )
    }
}
