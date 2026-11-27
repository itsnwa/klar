import AppKit
import SwiftUI

/// A SwiftUI view as a sheet on a browser window. The view gets the
/// window's models from its arguments, not the environment: a sheet is a
/// window of its own.
enum BrowserSheet {
    /// `content` gets what closes the sheet.
    static func present<Content: View>(
        on window: NSWindow?,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) {
        guard let window else { return }
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        let dismiss = { [weak window, weak sheet] in
            guard let window, let sheet else { return }
            window.endSheet(sheet)
        }
        let host = NSHostingController(rootView: content(dismiss))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

extension SidebarManager {
    /// The window showing this sidebar
    var window: NSWindow? {
        BrowserWindowSession.all.first { $0.sidebarManager === self }?.window
    }

    /// Clean Up Saved Tabs…
    func showCleanUp() {
        BrowserSheet.present(on: window) { dismiss in
            CleanUpSheet(sidebarManager: self, onDone: dismiss)
        }
    }
}
