import AppKit
import SwiftUI

/// About Klar's window, in place of AppKit's standard About panel: `AboutView` in a window with only a close button
/// over its content, sized to fit it, that closes on Escape too. Made the first time it's shown and kept for the
/// next; it's centered each time it opens.
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: AboutView())
        let window = AboutWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.title = "About Klar"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.setContentSize(hostingController.view.fittingSize)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// Closes on Escape, as a panel would.
private final class AboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

/// Klar › About Klar opens Klar's own About window.
struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Klar") { AboutWindowController.shared.show() }
        }
    }
}
