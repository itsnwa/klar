import Foundation
import AppKit

class SharingService {

    static func shareURL(_ url: String, title: String? = nil, from view: NSView) {
        let picker = makePicker(url: url, title: title)
        if let sidebar = BrowserWindowSession.session(for: view.window)?.sidebarStateManager {
            FloatingSidebarBlocker.shared.beginBlocking(sidebar)
            SharingPickerDelegate.shared.blockedSidebar = sidebar
        }
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    private static func makePicker(url: String, title: String?) -> NSSharingServicePicker {
        let cleanResult = URLUtilities.removeTrackingParameters(from: url)
        let shareURL = cleanResult.cleanURL

        var items: [Any] = []
        if let url = URL(string: shareURL) {
            items.append(url)
        } else {
            items.append(shareURL)
        }
        if let title = title {
            items.append(title)
        }

        let picker = NSSharingServicePicker(items: items)
        picker.delegate = SharingPickerDelegate.shared
        return picker
    }
}

/// Lets the floating sidebar close again once the share picker goes away.
/// The picker holds its delegate weakly, hence the shared instance.
private final class SharingPickerDelegate: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharingPickerDelegate()

    /// The sidebar the picker holds open
    weak var blockedSidebar: SidebarStateManager?

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Apple docs: this fires with `service == nil` when the user dismisses
        // the picker without choosing — covers both branches.
        if let blockedSidebar {
            FloatingSidebarBlocker.shared.endBlocking(blockedSidebar)
            self.blockedSidebar = nil
        }
    }
}

// MARK: - Add to Reading List

extension SharingService {
    /// Every share menu in Klar (a row's Share…, Share ▸ in a page's context
    /// menu, a website's share button) offers Klar's own Add to Reading
    /// List in place of the system's, whose share extension brings Safari to
    /// the front. A picker asks its delegate which services to show, so each
    /// picker's delegate gets a stand-in that swaps the service
    /// (`ReadingListPickerDelegate`): the pickers WebKit makes have its own
    /// delegates. Once, at launch.
    static func offerKlarReadingList() {
        let selector = #selector(setter: NSSharingServicePicker.delegate)
        guard let method = class_getInstanceMethod(NSSharingServicePicker.self, selector) else { return }
        typealias SetDelegate = @convention(c) (NSSharingServicePicker, Selector, NSSharingServicePickerDelegate?) -> Void
        let setDelegate = unsafeBitCast(method_getImplementation(method), to: SetDelegate.self)
        let setStandIn: @convention(block) (NSSharingServicePicker, NSSharingServicePickerDelegate?) -> Void = { picker, delegate in
            // The picker holds its delegate weakly; it keeps the stand-in
            let standIn = delegate.map(ReadingListPickerDelegate.init)
            objc_setAssociatedObject(picker, &ReadingListPickerDelegate.associationKey, standIn, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            setDelegate(picker, selector, standIn)
        }
        method_setImplementation(method, imp_implementationWithBlock(setStandIn))
    }

    /// Klar's Add to Reading List, shown like the system's: it adds the page
    /// with Safari's own service, leaving Safari where it is, and says so in
    /// the window's toast.
    fileprivate static func readingListService(like service: NSSharingService, for url: URL, title: String?) -> NSSharingService {
        NSSharingService(title: service.title, image: service.image, alternateImage: service.alternateImage) {
            let address = url.absoluteString
            let tabManager = BrowserWindowSession.current.tabManager
            // The row's title until Safari has fetched the page's own
            let title = title ?? tabManager.tabs.first { $0.url == address }?.title ?? ""
            SafariReadingListManager.shared.addToReadingList(url: address, title: title, reportingTo: tabManager.toastManager)
        }
    }
}

/// Stands in for a share picker's delegate: shows Klar's Add to Reading List
/// instead of the system's and passes everything else on to the delegate.
private final class ReadingListPickerDelegate: NSObject, NSSharingServicePickerDelegate {
    nonisolated(unsafe) static var associationKey: UInt8 = 0

    private weak var delegate: NSSharingServicePickerDelegate?

    init(_ delegate: NSSharingServicePickerDelegate) {
        self.delegate = delegate
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, sharingServicesForItems items: [Any], proposedSharingServices proposedServices: [NSSharingService]) -> [NSSharingService] {
        var services = delegate?.sharingServicePicker?(sharingServicePicker, sharingServicesForItems: items, proposedSharingServices: proposedServices) ?? proposedServices
        guard let systemService = NSSharingService(named: .addToSafariReadingList),
              let index = services.firstIndex(where: { $0.isEqual(systemService) }),
              let page = Self.page(in: items) else {
            return services
        }
        services[index] = SharingService.readingListService(like: services[index], for: page.url, title: page.title)
        return services
    }

    /// The web page shared: a URL, or one in a preview, which is how
    /// WebKit's share sheet (a website's share button) hands it over, with
    /// the title the website gave
    private static func page(in items: [Any]) -> (url: URL, title: String?)? {
        for item in items {
            if let url = item as? URL, SafariReadingListManager.canAdd(url: url.absoluteString) {
                return (url, nil)
            }
            if let preview = item as? NSPreviewRepresentableActivityItem,
               let url = preview.item as? URL, SafariReadingListManager.canAdd(url: url.absoluteString) {
                return (url, preview.title ?? nil)
            }
        }
        return nil
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        delegate?.sharingServicePicker?(sharingServicePicker, delegateFor: sharingService)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        delegate?.sharingServicePicker?(sharingServicePicker, didChoose: service)
    }

    func sharingServicePickerCollaborationModeRestrictions(_ sharingServicePicker: NSSharingServicePicker) -> [NSSharingServicePicker.CollaborationModeRestriction]? {
        delegate?.sharingServicePickerCollaborationModeRestrictions?(sharingServicePicker)
    }
}
