import AppKit

enum SidebarPasteboardTypes {
    static let sidebarItemUTI = "com.itsnwa.browser.sidebar-item"
    static let sidebarItem = NSPasteboard.PasteboardType(sidebarItemUTI)

    static let dragTypes: [NSPasteboard.PasteboardType] = [sidebarItem, .URL, .string]
    /// A link's title, which Finder names a link file after.
    static let urlName = NSPasteboard.PasteboardType("public.url-name")

    /// What a dragged sidebar item is allowed to do: moved within Klar
    /// (so a tab dropped on a page doesn't load there), and, a tab's link,
    /// copied into other apps.
    static func dragOperations(for context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : .move
    }
}

extension NSPasteboardItem {
    /// A sidebar item being dragged; a tab also as its `link`, for other
    /// apps: its address (a URL, and as text) and its title. Klar's own
    /// drop targets go by the item.
    static func sidebarItem(uuid: UUID, link: (url: String, title: String)? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(uuid.uuidString, forType: SidebarPasteboardTypes.sidebarItem)
        if let link, !link.url.isEmpty, URL(string: link.url) != nil {
            item.setString(link.url, forType: .URL)
            item.setString(link.url, forType: .string)
            item.setString(link.title, forType: SidebarPasteboardTypes.urlName)
        }
        return item
    }

    var sidebarItemUUID: UUID? {
        guard let raw = string(forType: SidebarPasteboardTypes.sidebarItem) else { return nil }
        return UUID(uuidString: raw)
    }
}

extension NSPasteboard {
    func sidebarItemUUIDs() -> [UUID] {
        guard let items = pasteboardItems else { return [] }
        return items.compactMap { $0.sidebarItemUUID }
    }
}

/// What a drag carries, read from its pasteboard once per drag: each read
/// asks the pasteboard server, and every drop target under the pointer (the
/// list's rows, the pinned sites, the space bar) asks on each move.
extension NSDraggingInfo {
    /// The sidebar items being dragged.
    var draggedSidebarItemUUIDs: [UUID] {
        DragPasteboardCache.value(\.sidebarItemUUIDs, for: self) {
            $0.sidebarItemUUIDs()
        }
    }

    /// A link (a URL, or text that reads as one), which opens a new tab.
    var hasDraggedLink: Bool {
        DragPasteboardCache.value(\.hasLink, for: self) { pasteboard in
            if pasteboard.canReadObject(forClasses: [NSURL.self], options: nil) { return true }
            if pasteboard.string(forType: .URL) != nil { return true }
            if let s = pasteboard.string(forType: .string), URL(string: s) != nil { return true }
            return false
        }
    }

    /// A web page's address, to pin or open in a space.
    var draggedWebURL: String? {
        DragPasteboardCache.value(\.webURL, for: self) { pasteboard in
            if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?.first as? URL,
               url.scheme == "http" || url.scheme == "https" {
                return url.absoluteString
            }
            return nil
        }
    }
}

/// The current drag's, by its sequence number: a new drag starts afresh.
private struct DragPasteboardCache {
    var sidebarItemUUIDs: [UUID]?
    var hasLink: Bool?
    var webURL: String??

    private static var sequenceNumber: Int?
    private static var current = DragPasteboardCache()

    static func value<T>(_ keyPath: WritableKeyPath<DragPasteboardCache, T?>, for sender: NSDraggingInfo,
                         read: (NSPasteboard) -> T) -> T {
        if sequenceNumber != sender.draggingSequenceNumber {
            sequenceNumber = sender.draggingSequenceNumber
            current = DragPasteboardCache()
        }
        if let value = current[keyPath: keyPath] {
            return value
        }
        let value = read(sender.draggingPasteboard)
        current[keyPath: keyPath] = value
        return value
    }
}
