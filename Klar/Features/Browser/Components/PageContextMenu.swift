import AppKit
import UniformTypeIdentifiers
import WebKit

/// What a context menu was opened on, from WebKit's hit test
/// (`_WKContextMenuElementInfo`'s `_WKHitTestResult`): the frame, the link
/// and image, and whether it's the page's or the frame's own background
/// rather than a link, image, video, selection or text field, which have
/// menus of their own.
struct ContextMenuHit {
    let frame: WKFrameInfo
    let linkURL: URL?
    let imageURL: URL?
    let isBackground: Bool

    init?(element: AnyObject) {
        guard let element = element as? NSObject,
              let hit = element.privateValue(forKey: "hitTestResult") as? NSObject,
              let frame = hit.privateValue(forKey: "frameInfo") as? WKFrameInfo else { return nil }
        self.frame = frame
        linkURL = hit.privateValue(forKey: "absoluteLinkURL") as? URL
        imageURL = hit.privateValue(forKey: "absoluteImageURL") as? URL
        isBackground = linkURL == nil && imageURL == nil
            && hit.privateValue(forKey: "absoluteMediaURL") == nil
            && hit.privateValue(forKey: "isContentEditable") as? Bool != true
            && hit.privateValue(forKey: "isSelected") as? Bool != true
    }
}

// MARK: - Opening Links, Images and Frames

extension CustomWKWebView {
    /// Klar's own Open Link (or Image) in New Window, which opens a browser
    /// window, in place of WebKit's, which opens the address from the page
    /// and so in a new tab. WebKit's stays in the menu, hidden: Open … in
    /// New Tab, just before it, goes through it. With them, that item's ⌥
    /// alternate.
    func newWindowItems(replacing webKitItem: NSMenuItem, newTabItem: NSMenuItem, noun: String, url: URL) -> [NSMenuItem] {
        webKitItem.isHidden = true
        return privateTabAlternate(of: newTabItem, noun: noun, url: url)
            + [pageItem("Open \(noun) in New Window", #selector(openInNewWindow(_:)), url)]
    }

    /// Open … in New Tab's alternate with ⌥ held: in a new private tab.
    /// Not in a private tab, whose new tabs are private anyway.
    func privateTabAlternate(of newTabItem: NSMenuItem, noun: String, url: URL) -> [NSMenuItem] {
        guard !isPrivateBrowsing else { return [] }
        newTabItem.keyEquivalentModifierMask = []
        let alternate = pageItem("Open \(noun) in New Private Tab", #selector(openInNewPrivateTab(_:)), url)
        alternate.keyEquivalentModifierMask = .option
        alternate.isAlternate = true
        return [alternate]
    }

    /// In the background, as a link opened in a new tab
    @objc private func openInNewTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openInNewTab(url, isPrivate: isPrivateBrowsing)
    }

    @objc private func openInNewPrivateTab(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openInNewTab(url, isPrivate: true)
    }

    private func openInNewTab(_ url: URL, isPrivate: Bool) {
        // A popup's page has no tabs of its own
        let tabManager = tabManager ?? BrowserWindowSession.current.tabManager
        _ = tabManager.createNewTab(url: url.absoluteString, parentTabId: tabID, activate: false, isPrivate: isPrivate)
    }

    @objc private func openInNewWindow(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        BrowserWindow.openNew(showing: url, isPrivate: isPrivateBrowsing)
    }

    private func pageItem(_ title: String, _ action: Selector, _ representedObject: Any?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        return item
    }
}

// MARK: - The Page's and Frames' Items

/// The items for a page's or a frame's own menu, around WebKit's
/// (Back, Forward and Reload for the page, Open Frame in New Window for a
/// frame, and Inspect Element with developer tools on):
///
/// - Page: Back, Forward, Reload Page | Show Page Source, Save Page As… |
///   Print Page… | Inspect Element
/// - Frame: Reload Page | Open Frame in New Tab, Open Frame in New Window |
///   Show Frame Source, Save Frame As… | Print Frame…, Print Window… |
///   Inspect Element
///
/// Show … Source opens the Web Inspector, so it's there only with Inspect
/// Element.
extension CustomWKWebView {
    func addPageItems(to menu: NSMenu, for hit: ContextMenuHit) {
        guard hit.isBackground else { return }
        let frame = hit.frame
        let noun = frame.isMainFrame ? "Page" : "Frame"

        if let reload = menu.items.first(where: { $0.identifier == .webKitReload }) {
            reload.title = "Reload Page"
        } else if !frame.isMainFrame {
            let reload = NSMenuItem(title: "Reload Page", action: #selector(WKWebView.reload(_:)), keyEquivalent: "")
            reload.target = self
            menu.insertItem(reload, at: 0)
            menu.insertItem(.separator(), at: 1)
        }

        // WebKit's own item opens the frame from the page, which Klar
        // takes for a new tab
        if let webKitItem = menu.items.first(where: { $0.identifier == .webKitOpenFrameInNewWindow }),
           let url = frame.request.url {
            webKitItem.target = self
            webKitItem.action = #selector(openInNewWindow(_:))
            webKitItem.representedObject = url
            let newTab = pageItem("Open Frame in New Tab", #selector(openInNewTab(_:)), url)
            let index = menu.index(of: webKitItem)
            for (offset, item) in ([newTab] + privateTabAlternate(of: newTab, noun: "Frame", url: url)).enumerated() {
                menu.insertItem(item, at: index + offset)
            }
        }

        var items: [NSMenuItem] = [.separator()]
        if menu.items.contains(where: { $0.identifier == .webKitInspectElement }) {
            items.append(pageItem("Show \(noun) Source", #selector(showFrameSource(_:)), frame))
        }
        items.append(pageItem("Save \(noun) As…", #selector(saveFrameAs(_:)), frame))
        items.append(.separator())
        let print = pageItem("Print \(noun)…", #selector(printFrame(_:)), frame)
        if frame.isMainFrame {
            print.image = NSImage(systemSymbolName: "printer", accessibilityDescription: nil)
        }
        items.append(print)
        if !frame.isMainFrame {
            items.append(pageItem("Print Window…", #selector(printFrame(_:)), nil))
        }
        items.append(.separator())

        let index = menu.items.firstIndex { $0.identifier == .webKitInspectElement } ?? menu.items.count
        for (offset, item) in items.enumerated() {
            menu.insertItem(item, at: index + offset)
        }
    }

    /// The frame's source in the Web Inspector's Sources tab
    @objc private func showFrameSource(_ sender: NSMenuItem) {
        let selector = NSSelectorFromString("showMainResourceForFrame:")
        guard let frame = sender.representedObject as? WKFrameInfo,
              let handle = frame.privateValue(forKey: "_handle"),
              let inspector = privateValue(forKey: "_inspector") as? NSObject,
              inspector.responds(to: selector) else { return }
        inspector.perform(selector, with: handle)
    }

    @objc private func saveFrameAs(_ sender: NSMenuItem) {
        guard let frame = sender.representedObject as? WKFrameInfo,
              let window = presentationWindow else { return }
        PageSavePanel(webView: self, frame: frame).begin(in: window)
    }

    /// A frame's item prints the frame; the page's and Print Window… the page
    @objc private func printFrame(_ sender: NSMenuItem) {
        let frame = sender.representedObject as? WKFrameInfo
        let handle = frame.flatMap { $0.isMainFrame ? nil : $0.privateValue(forKey: "_handle") as AnyObject? }
        (uiDelegate as? CustomWKUIDelegate)?.runPrintPanel(for: handle, in: self)
    }
}

// MARK: - Save Page As

/// Save Page As… and Save Frame As…: a save panel named after
/// the page's title, in either format: a web archive (the page with its
/// images, styles and scripts) or the page's source.
final class PageSavePanel: NSObject {
    enum Format: Int, CaseIterable {
        case webArchive, pageSource

        var title: String {
            switch self {
            case .webArchive: "Web Archive"
            case .pageSource: "Page Source"
            }
        }

        var contentType: UTType {
            switch self {
            case .webArchive: .webArchive
            case .pageSource: .html
            }
        }
    }

    /// The one picked last, for the next page
    private static var lastFormat: Format = .webArchive

    private let webView: WKWebView
    private let frame: WKFrameInfo
    private let panel = NSSavePanel()
    private let formatButton = NSPopUpButton()

    private var format: Format {
        Format(rawValue: formatButton.indexOfSelectedItem) ?? .webArchive
    }

    init(webView: WKWebView, frame: WKFrameInfo) {
        self.webView = webView
        self.frame = frame
        super.init()
    }

    /// Shows the panel as a sheet on the window; it keeps itself until then
    func begin(in window: NSWindow) {
        formatButton.addItems(withTitles: Format.allCases.map(\.title))
        formatButton.selectItem(at: Self.lastFormat.rawValue)
        formatButton.target = self
        formatButton.action = #selector(formatDidChange)

        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), formatButton])
        accessory.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        accessory.setFrameSize(accessory.fittingSize)
        panel.accessoryView = accessory

        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [Self.lastFormat.contentType]
        panel.canSelectHiddenExtension = true
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = self.panel.url else { return }
            Self.lastFormat = self.format
            self.save(self.format, to: url, window: window)
        }
    }

    @objc private func formatDidChange() {
        panel.allowedContentTypes = [format.contentType]
    }

    /// The page's (or frame's) title, else its address's last part or host
    private var fileName: String {
        let title = frame.isMainFrame ? webView.title : frame.privateValue(forKey: "_title") as? String
        let url = frame.request.url
        let name = [title, url?.lastPathComponent, url?.host()]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "/" } ?? "Untitled"
        return name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private func save(_ format: Format, to url: URL, window: NSWindow) {
        let write: @MainActor (Data?, Error?) -> Void = { [webView] data, error in
            do {
                guard let data else { throw error ?? CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            } catch {
                logError(.webView, "Couldn't save the page: \(error.localizedDescription)", isPrivate: webView.isPrivateBrowsing)
                let alert = NSAlert()
                alert.messageText = "The page couldn't be saved."
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
        switch format {
        case .webArchive: webView.createWebArchive(of: frame, completion: write)
        case .pageSource: webView.pageSource(of: frame, completion: write)
        }
    }
}

extension WKWebView {
    /// The frame as a web archive (`_createWebArchiveForFrame:completionHandler:`;
    /// without it, the page's)
    func createWebArchive(of frame: WKFrameInfo, completion: @escaping @MainActor (Data?, Error?) -> Void) {
        let selector = NSSelectorFromString("_createWebArchiveForFrame:completionHandler:")
        guard responds(to: selector) else {
            createWebArchiveData { result in
                switch result {
                case .success(let data): completion(data, nil)
                case .failure(let error): completion(nil, error)
                }
            }
            return
        }
        typealias CreateArchive = @convention(c) (NSObject, Selector, WKFrameInfo, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
        unsafeBitCast(method(for: selector), to: CreateArchive.self)(self, selector, frame) { data, error in
            completion(data as Data?, error)
        }
    }

    /// The frame's source: the page's as it came
    /// (`_getMainResourceDataWithCompletionHandler:`), a frame's from its
    /// web archive, where it's the frame's markup
    func pageSource(of frame: WKFrameInfo, completion: @escaping @MainActor (Data?, Error?) -> Void) {
        let selector = NSSelectorFromString("_getMainResourceDataWithCompletionHandler:")
        if frame.isMainFrame, responds(to: selector) {
            typealias GetMainResource = @convention(c) (NSObject, Selector, @escaping @convention(block) (NSData?, NSError?) -> Void) -> Void
            unsafeBitCast(method(for: selector), to: GetMainResource.self)(self, selector) { data, error in
                completion(data as Data?, error)
            }
            return
        }
        createWebArchive(of: frame) { data, error in
            let archive = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
            let mainResource = archive?["WebMainResource"] as? [String: Any]
            completion(mainResource?["WebResourceData"] as? Data, error)
        }
    }
}

// MARK: - Helpers

private extension NSUserInterfaceItemIdentifier {
    static let webKitReload = Self("WKMenuItemIdentifierReload")
    static let webKitOpenFrameInNewWindow = Self("WKMenuItemIdentifierOpenFrameInNewWindow")
    static let webKitInspectElement = Self("WKMenuItemIdentifierInspectElement")
}

extension NSMenu {
    /// No separator at either end or next to another, among the items shown
    func removeExtraSeparators() {
        var followsSeparator = true
        for item in items where !item.isHidden {
            if item.isSeparatorItem && followsSeparator {
                removeItem(item)
                continue
            }
            followsSeparator = item.isSeparatorItem
        }
        if let last = items.last(where: { !$0.isHidden }), last.isSeparatorItem {
            removeItem(last)
        }
    }
}

private extension NSObject {
    /// A private property, if the object has it on this macOS
    func privateValue(forKey key: String) -> Any? {
        responds(to: NSSelectorFromString(key)) ? value(forKey: key) : nil
    }
}
