import Foundation
import WebKit
import AppKit

// Custom actions for context menu
enum ContextualMenuAction {
    case openLinkInNewTab
    case openImageInNewTab
    case copyLinkAddress
    case copyImageAddress
    case downloadLinkedFileAs
    case saveImageToDownloads
    case saveImageAs
}

// Custom WKWebView subclass to handle context menu customization on macOS
class CustomWKWebView: WKWebView {
    
    // Store the click position for use in JavaScript evaluation
    private var lastClickPoint: CGPoint = .zero
    
    // Track custom action selected from context menu
    var contextualMenuAction: ContextualMenuAction?

    /// What the menu about to open was opened on, from WebKit's UI
    /// delegate, which is shown the menu first (`CustomWKUIDelegate`)
    var contextMenuHit: ContextMenuHit?
    
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        
        // Enable context menu
        self.allowsLinkPreview = true
        registerForSidebarItemDrags()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        // Enable context menu
        self.allowsLinkPreview = true
        registerForSidebarItemDrags()
    }

    /// Besides WebKit's own types: a tab without an address to carry along
    /// can still be dropped beside the page, and so can another pane (see
    /// Split View below)
    private func registerForSidebarItemDrags() {
        registerForDraggedTypes(registeredDraggedTypes + [SidebarPasteboardTypes.sidebarItem, SplitPaneControlsView.pasteboardType])
    }

    // Override the proper method for context menu customization
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        // Store the click position for context menu
        lastClickPoint = convert(event.locationInWindow, from: nil)
        
        // Call super first to let WebKit do its setup
        super.willOpenMenu(menu, with: event)
        
        // Now customize the menu
        customizeContextMenu(menu)
    }
    
    private func customizeContextMenu(_ menu: NSMenu) {
        // Add our custom items based on existing WebKit menu items
        var itemsToAdd: [(NSMenuItem, Int)] = []
        let hit = contextMenuHit
        contextMenuHit = nil
        
        // Look for WebKit's standard menu items to determine context
        for (index, item) in menu.items.enumerated() {
            guard let identifier = item.identifier?.rawValue else { 
                continue 
            }
            
            // Add custom items for links
            if identifier == "WKMenuItemIdentifierOpenLinkInNewWindow" {
                let openInNewTabItem = NSMenuItem(title: "Open Link in New Tab", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                openInNewTabItem.target = self
                openInNewTabItem.identifier = NSUserInterfaceItemIdentifier("customOpenLinkInNewTab")
                openInNewTabItem.representedObject = item // Store original item for URL extraction
                // Before New Window
                itemsToAdd.append((openInNewTabItem, index))
                if let url = hit?.linkURL {
                    for newItem in newWindowItems(replacing: item, newTabItem: openInNewTabItem, noun: "Link", url: url) {
                        itemsToAdd.append((newItem, index))
                    }
                }
            }
            
            // Add custom download item for links
            if identifier == "WKMenuItemIdentifierDownloadLinkedFile" {
                let downloadAsItem = NSMenuItem(title: "Download Linked File As...", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                downloadAsItem.target = self
                downloadAsItem.identifier = NSUserInterfaceItemIdentifier("customDownloadLinkedFileAs")
                downloadAsItem.representedObject = item
                itemsToAdd.append((downloadAsItem, index + 1))
            }
            
            // Add custom items for images
            if identifier == "WKMenuItemIdentifierOpenImageInNewWindow" {
                let openImageInNewTabItem = NSMenuItem(title: "Open Image in New Tab", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                openImageInNewTabItem.target = self
                openImageInNewTabItem.identifier = NSUserInterfaceItemIdentifier("customOpenImageInNewTab")
                openImageInNewTabItem.representedObject = item
                itemsToAdd.append((openImageInNewTabItem, index))
                if let url = hit?.imageURL {
                    for newItem in newWindowItems(replacing: item, newTabItem: openImageInNewTabItem, noun: "Image", url: url) {
                        itemsToAdd.append((newItem, index))
                    }
                }
                
                let copyImageAddressItem = NSMenuItem(title: "Copy Image Address", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                copyImageAddressItem.target = self
                copyImageAddressItem.identifier = NSUserInterfaceItemIdentifier("customCopyImageAddress")
                copyImageAddressItem.representedObject = item
                itemsToAdd.append((copyImageAddressItem, index + 2))
            }
            
            // Add custom image saving items and hide the default "Download Image"
            if identifier == "WKMenuItemIdentifierDownloadImage" {
                // Hide the default "Download Image" item
                item.isHidden = true
                
                let saveToDownloadsItem = NSMenuItem(title: "Save Image to \"Downloads\"", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                saveToDownloadsItem.target = self
                saveToDownloadsItem.identifier = NSUserInterfaceItemIdentifier("customSaveImageToDownloads")
                saveToDownloadsItem.representedObject = item
                itemsToAdd.append((saveToDownloadsItem, index))
                
                let saveAsItem = NSMenuItem(title: "Save Image As...", action: #selector(processCustomMenuItem(_:)), keyEquivalent: "")
                saveAsItem.target = self
                saveAsItem.identifier = NSUserInterfaceItemIdentifier("customSaveImageAs")
                saveAsItem.representedObject = item
                itemsToAdd.append((saveAsItem, index + 1))
            }
        }
        
        // Insert items in reverse order to maintain correct positions
        for (item, position) in itemsToAdd.reversed() {
            menu.insertItem(item, at: position)
        }

        // The page's or a frame's own items
        if let hit {
            addPageItems(to: menu, for: hit)
        }

        // Extensions' own items (contextMenus API), at the end
        let extensionItems = ExtensionManager.shared.contextMenuItems(for: self)
        if !extensionItems.isEmpty {
            menu.addItem(.separator())
            extensionItems.forEach { menu.addItem($0) }
        }

        menu.removeExtraSeparators()
    }
    
    @objc private func processCustomMenuItem(_ menuItem: NSMenuItem) {
        self.contextualMenuAction = nil
        
        guard let originalMenuItem = menuItem.representedObject as? NSMenuItem else {
            return
        }
        
        // Set the custom action based on the menu item identifier
        if let identifier = menuItem.identifier?.rawValue {
            switch identifier {
            case "customOpenLinkInNewTab":
                self.contextualMenuAction = .openLinkInNewTab
            case "customOpenImageInNewTab":
                self.contextualMenuAction = .openImageInNewTab
            case "customCopyLinkAddress":
                self.contextualMenuAction = .copyLinkAddress
            case "customCopyImageAddress":
                self.contextualMenuAction = .copyImageAddress
            case "customDownloadLinkedFileAs":
                self.contextualMenuAction = .downloadLinkedFileAs
            case "customSaveImageToDownloads":
                self.contextualMenuAction = .saveImageToDownloads
            case "customSaveImageAs":
                self.contextualMenuAction = .saveImageAs
            default:
                break
            }
        }
        
        // For some actions, we need to handle them directly instead of relying on createWebViewWith
        if shouldHandleActionDirectly(self.contextualMenuAction) {
            handleActionDirectly(self.contextualMenuAction, menuItem: menuItem)
        } else {
            // Trigger the original WebKit action to get the URL via navigation delegate
            if let action = originalMenuItem.action {
                _ = originalMenuItem.target?.perform(action, with: originalMenuItem)
            }
        }
    }
    
    private func shouldHandleActionDirectly(_ action: ContextualMenuAction?) -> Bool {
        guard let action = action else { return false }
        
        // Actions that don't trigger createWebViewWith should be handled directly
        switch action {
        case .downloadLinkedFileAs, .saveImageToDownloads, .saveImageAs, .copyLinkAddress, .copyImageAddress:
            return true
        case .openLinkInNewTab, .openImageInNewTab:
            return false // These should go through createWebViewWith
        }
    }
    
    private func handleActionDirectly(_ action: ContextualMenuAction?, menuItem: NSMenuItem) {
        guard let action = action else { return }
        
        // First try to extract URL from the original WebKit menu item
        if let originalMenuItem = menuItem.representedObject as? NSMenuItem,
           let url = extractURLFromWebKitMenuItem(originalMenuItem) {
            
            logDebug(.webView, "Using URL from WebKit menu item: \(url.absoluteString)")
            
            // Post notification to CustomWKUIDelegate to handle the action
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("HandleCustomContextAction"),
                    object: nil,
                    userInfo: [
                        "action": action,
                        "url": url.absoluteString,
                        "webView": self
                    ]
                )
            }
            return
        }
        
        // Fallback to JavaScript detection if WebKit menu item doesn't have URL
        detectURLFromClickPosition { [weak self] url in
            guard let self = self, let url = url else {
                logError(.webView, "Could not determine URL for direct action", isPrivate: self?.isPrivateBrowsing ?? false)
                return
            }
            
            logDebug(.webView, "Using URL from JavaScript detection: \(url.absoluteString)")
            
            // Post notification to CustomWKUIDelegate to handle the action
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: NSNotification.Name("HandleCustomContextAction"),
                    object: nil,
                    userInfo: [
                        "action": action,
                        "url": url.absoluteString,
                        "webView": self
                    ]
                )
            }
        }
    }
    
    private func extractURLFromWebKitMenuItem(_ menuItem: NSMenuItem) -> URL? {
        // WebKit menu items often store URL information in their representedObject or userInfo
        // This is more reliable than JavaScript detection for standard menu items
        
        // Method 1: Check if the menu item has a URL in its representedObject
        if let url = menuItem.representedObject as? URL {
            return url
        }
        
        // Method 2: Check representedObject for URL string
        if let urlString = menuItem.representedObject as? String,
           let url = URL(string: urlString) {
            return url
        }
        
        // Method 3: Try to extract from the menu item's action target
        // Some WebKit menu items store the URL in their target object
        if let target = menuItem.target as? NSObject,
           target.responds(to: Selector(("URL"))) {
            if let url = target.value(forKey: "URL") as? URL {
                return url
            }
        }
        
        // Method 4: Check if the menu item itself has URL-related properties
        // This uses reflection to look for URL properties
        let mirror = Mirror(reflecting: menuItem)
        for child in mirror.children {
            if let label = child.label,
               label.lowercased().contains("url"),
               let url = child.value as? URL {
                return url
            }
        }
        
        return nil
    }
    
    private func detectURLFromClickPosition(completion: @escaping (URL?) -> Void) {
        let x = lastClickPoint.x
        let y = bounds.height - lastClickPoint.y // Convert to web coordinates
        
        let javascript = """
            (function(x, y) {
                const element = document.elementFromPoint(x, y);
                if (!element) return null;
                
                // First priority: Check if we clicked directly on an image
                if (element.tagName === 'IMG' && element.src) {
                    return element.src;
                }
                
                // Second priority: Check for image inside the clicked element
                const img = element.querySelector('img');
                if (img && img.src) {
                    return img.src;
                }
                
                // Third priority: Check parent elements for images (for overlays/wrappers)
                let parent = element.parentElement;
                while (parent && parent !== document.body) {
                    const parentImg = parent.querySelector('img');
                    if (parentImg && parentImg.src) {
                        return parentImg.src;
                    }
                    parent = parent.parentElement;
                }
                
                // Fourth priority: Check if element has background-image
                const style = window.getComputedStyle(element);
                const bgImage = style.backgroundImage;
                if (bgImage && bgImage !== 'none') {
                    const match = bgImage.match(/url\\(["']?([^"'\\)]+)["']?\\)/);
                    if (match) {
                        return match[1];
                    }
                }
                
                // Fifth priority: Check data attributes for image URLs
                if (element.dataset) {
                    const possibleURLs = ['src', 'originalSrc', 'fullSrc', 'highresSrc', 'lazySrc', 'url', 'image'];
                    for (const attr of possibleURLs) {
                        if (element.dataset[attr]) {
                            return element.dataset[attr];
                        }
                    }
                }
                
                // Sixth priority: Check various attributes that might contain image URLs
                const urlAttributes = ['data-src', 'data-original', 'data-lazy-src', 'data-full-src'];
                for (const attr of urlAttributes) {
                    const value = element.getAttribute(attr);
                    if (value && (value.includes('.jpg') || value.includes('.png') || value.includes('.gif') || value.includes('.webp') || value.includes('.jpeg'))) {
                        return value;
                    }
                }
                
                // Last priority: Check for link URL (only if no image found)
                const link = element.closest('a');
                if (link && link.href) {
                    return link.href;
                }
                
                return null;
            })(\(x), \(y))
        """
        
        evaluateJavaScript(javascript) { [isPrivate = isPrivateBrowsing] result, error in
            if let error = error {
                logError(.webView, "JavaScript error detecting URL: \(error)", isPrivate: isPrivate)
                completion(nil)
                return
            }
            
            if let urlString = result as? String, let url = URL(string: urlString) {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }
    
    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        
        // Reset the custom action after a delay (menu actions are processed asynchronously)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.contextualMenuAction = nil
        }
    }
    
    override func menu(for event: NSEvent) -> NSMenu? {
        logDebug(.webView, "🔍 menu(for event:) method called!")
        
        // This method might not be called due to SwiftUI interference,
        // so we handle context menus in rightMouseDown instead
        return super.menu(for: event)
    }

    // MARK: - Split View

    /// The tab this page is in, and its manager (set by its coordinator):
    /// a click focuses its pane of a split view, and a tab dragged from the
    /// sidebar onto it opens beside it.
    var tabID: UUID?
    weak var tabManager: TabManager?

    override func mouseDown(with event: NSEvent) {
        focusPane()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        focusPane()
        super.rightMouseDown(with: event)
    }

    private func focusPane() {
        guard let tabID else { return }
        tabManager?.focusPane(tabID)
    }

    /// A tab or saved tab dragged from the sidebar (or a pinned site), or a
    /// pane of the split view by its handle. Such drags are the split view's
    /// alone: WebKit never sees them, so a page doesn't load a tab dropped
    /// on it.
    private func isSidebarItemDrag(_ sender: NSDraggingInfo?) -> Bool {
        guard let types = sender?.draggingPasteboard.types else { return false }
        return types.contains(SidebarPasteboardTypes.sidebarItem) || types.contains(SplitPaneControlsView.pasteboardType)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isSidebarItemDrag(sender) else { return super.draggingEntered(sender) }
        let operation = updateSplitDrop(sender)
        logDebug(.dragDrop, "Sidebar item dragged over the page of tab \(tabID?.uuidString.prefix(8) ?? "?"): \(operation.isEmpty ? "refused" : "split")")
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isSidebarItemDrag(sender) else { return super.draggingUpdated(sender) }
        return updateSplitDrop(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard isSidebarItemDrag(sender) else { return super.draggingExited(sender) }
        endSplitDrop()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isSidebarItemDrag(sender) else { return super.prepareForDragOperation(sender) }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isSidebarItemDrag(sender) else { return super.performDragOperation(sender) }
        guard let tabID, let tabManager else { return false }
        return tabManager.performSplitDrop(sender, over: tabID, on: splitEdge(at: sender.draggingLocation))
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard isSidebarItemDrag(sender) else { return super.concludeDragOperation(sender) }
    }

    /// No super for other drags: neither WKWebView nor NSView implements
    /// `draggingEnded:`, so calling it would raise an unrecognized selector.
    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard isSidebarItemDrag(sender) else { return }
        endSplitDrop()
    }

    /// Shows where the dragged tab would go, if it can go beside this page
    private func updateSplitDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let tabID, let tabManager else { return [] }
        return tabManager.updateSplitDrop(sender, over: tabID, on: splitEdge(at: sender.draggingLocation))
    }

    private func endSplitDrop() {
        guard let tabID else { return }
        tabManager?.endSplitDrop(over: tabID)
    }

    /// The side of the page nearest the pointer, where the dragged tab
    /// would go. The top and bottom count half as far in, so across the
    /// middle of the page it goes beside it.
    private func splitEdge(at windowLocation: NSPoint) -> SplitEdge {
        let point = convert(windowLocation, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .right }
        let x = point.x / bounds.width
        let y = isFlipped ? point.y / bounds.height : 1 - point.y / bounds.height
        let distances: [(edge: SplitEdge, distance: CGFloat)] = [
            (.left, x), (.right, 1 - x), (.top, y * 2), (.bottom, (1 - y) * 2)
        ]
        return distances.min { $0.distance < $1.distance }?.edge ?? .right
    }

    // MARK: - Keys the Page Didn't Handle

    /// WebKit passes a key press on up the responder chain when the page
    /// didn't handle it (a game listening to WASD without `preventDefault`,
    /// an arrow key with nothing left to scroll), and at the end of the chain
    /// AppKit beeps — on every repeat of a key held down. Keys stop here
    /// instead: a ⌘ shortcut has been through the menus by
    /// now (WebKit sends it again once the page passes on it), so nothing
    /// further up takes it either. Only Escape in WebKit's full-screen
    /// window goes on, which exits on it (anywhere else nothing takes it: a
    /// page's image viewer closing on Escape would beep). Takes the place
    /// of WebKit's `-[WKWebView _web_superKeyDown:]`, its `[super keyDown:]`.
    @objc(_web_superKeyDown:)
    private func passUnhandledKeyDown(_ event: NSEvent) {
        if event.keyCode == 53, BrowserWindow.isFullScreenPage(window) {
            nextResponder?.keyDown(with: event)
        }
    }

}
