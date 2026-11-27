import SwiftUI
import AppKit

/// Klar's shortcuts in the browser windows: one set of event monitors for
/// the app, acting on the window a key was typed in (its session's tabs,
/// sidebar and find panel).
class KeyboardHandler {
    /// Made once, at launch (`KlarApp.init`), and kept: its monitors go with it
    static let shared = KeyboardHandler()

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var mouseButtonMonitor: Any?
    
    private init() {
        setupKeyboardMonitoring()
    }
    
    isolated deinit {
        stopKeyboardMonitoring()
    }
    
    private func setupKeyboardMonitoring() {
        // Local monitor for when app is active - this is the key to preventing beeps
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // If we handle the event, return nil to consume it completely
            if let session = Self.session(receiving: event), self.shouldHandleEvent(event, in: session) {
                self.handleKeyEvent(event, in: session)
                return nil // This prevents the beep by consuming the event
            }

            // Extensions' keyboard shortcuts (manifest "commands"), after
            // Klar's own
            if ExtensionManager.shared.performCommand(for: event) {
                return nil
            }

            return event
        }

        // Mouse side buttons (XButton1 = back, XButton2 = forward) come through as .otherMouseDown
        mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            // Only over a browser window's pages, not a popup's or the Web
            // Inspector's: that window's
            guard let tabManager = Self.session(receiving: event)?.tabManager else { return event }

            switch event.buttonNumber {
            case 3:
                DispatchQueue.main.async { tabManager.goBackInCurrentTab() }
                return nil
            case 4:
                DispatchQueue.main.async { tabManager.goForwardInCurrentTab() }
                return nil
            default:
                return event
            }
        }
    }

    private func stopKeyboardMonitoring() {
        if let localMonitor = localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let globalMonitor = globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let mouseButtonMonitor = mouseButtonMonitor {
            NSEvent.removeMonitor(mouseButtonMonitor)
            self.mouseButtonMonitor = nil
        }
    }
    
    /// The modifier keys held, which the shortcuts are compared with. Not
    /// everything device-independent: that includes Caps Lock, and with it
    /// on ⌘R, ⌘S, ⌘[ and ⌘] (which no menu item backs up) did nothing.
    private static func shortcutModifiers(of event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection([.command, .shift, .option, .control])
    }

    /// The text being typed has marked text: an input method's, not yet
    /// part of it.
    private static func isComposingText(for event: NSEvent) -> Bool {
        let window = event.window ?? NSApp.keyWindow
        return (window?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    /// The browser window an event is for, with no sheet over it. Keys
    /// typed in Settings, a popup, an extension's window, the Web Inspector,
    /// a sheet, an alert or a page in full screen are that window's (⌘W
    /// closes it, ⌘F finds in it, Escape leaves full screen). The menu's
    /// commands look at the key window themselves.
    private static func session(receiving event: NSEvent) -> BrowserWindowSession? {
        guard BrowserWindow.receivesShortcuts(event.window) else { return nil }
        return BrowserWindowSession.session(for: event.window)
    }

    private func shouldHandleEvent(_ event: NSEvent, in session: BrowserWindowSession) -> Bool {
        let tabManager = session.tabManager
        let findManager: FindManager? = session.findManager

        let modifiers = Self.shortcutModifiers(of: event)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = Int(event.keyCode)
        
        // Debug logging for arrow keys to see what modifiers are actually present
        if keyCode == 126 || keyCode == 125 { // Up or Down arrows
        }
        
        // Check if this is CMD+L, CMD+T, CMD+K, CMD+W, CMD+[, CMD+], CMD+R, CMD+S, CMD+F, or zoom shortcuts
        if modifiers == .command {
            switch characters {
            case "l", "t", "k", "w", "[", "]", "r", "s", "f":
                return true
            case "+", "=", "-", "0": // Zoom shortcuts: Cmd+Plus, Cmd+Minus, Cmd+0
                return true
            default:
                break
            }
        }
        
        // Check for CMD+SHIFT+C to copy URL
        if modifiers == [.command, .shift] && characters == "c" {
            return true
        }
        
        // Check for CMD+OPT+I to toggle web inspector
        if modifiers == [.command, .option] && characters == "i" {
            return true
        }
        
        // Check for CMD+OPT+Up/Down arrow keys for tab navigation
        // Filter out system-added flags (function, numericPad) that come with arrow keys
        
        if keyCode == 126 || keyCode == 125 { // Up or Down arrows
            let filteredModifiers = modifiers.subtracting([.function, .numericPad])
            if filteredModifiers == [.command, .option] {
                return true
            }
        }
        
        // While an input method is composing (Chinese, Japanese, Korean, the
        // accent menu), these keys are its own: confirming or cancelling the
        // text, or picking a candidate.
        if [126, 125, 36, 53].contains(keyCode), Self.isComposingText(for: event) {
            return false
        }

        // Check if command palette is open and we need to handle navigation
        if tabManager.showCommandPalette {
            switch keyCode {
            case 126, 125, 36, 53: // Up, Down, Return, Escape
                return true
            default:
                break
            }
        }
        
        // Check if find panel is open and we need to handle navigation
        if let findManager = findManager, findManager.findState.isVisible {
            switch keyCode {
            case 53: // Escape - stop an answer or close Find
                return true
            case 36: // Return/Enter - find next or previous based on shift
                // Only from the search field, and only while it steps through
                // matches. Otherwise Return belongs to whatever has focus: the
                // panel's own submit (Ask AI, sending a chat message) or the
                // page (e.g. submitting a form) — swallowing it here broke both.
                let findState = findManager.findState
                return findManager.isInputFocused && findState.mode == .search && !findState.shouldShowAIFallback
            default:
                // Check for CMD+G and CMD+SHIFT+G for find navigation
                if modifiers == .command && characters == "g" {
                    return true
                } else if modifiers == [.command, .shift] && characters == "g" {
                    return true
                }
                break
            }
        }
        
        return false
    }
    
    private func handleKeyEvent(_ event: NSEvent, in session: BrowserWindowSession) {
        let tabManager = session.tabManager
        let findManager: FindManager? = session.findManager
        let sidebarStateManager = session.sidebarStateManager

        let modifiers = Self.shortcutModifiers(of: event)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let keyCode = Int(event.keyCode)
        
        // Debug logging
        
        // Handle CMD+L, CMD+T, CMD+W, CMD+[, CMD+], CMD+R, and CMD+S
        if modifiers == .command {
            switch characters {
            case "l":
                DispatchQueue.main.async {
                    // If no tabs are open or all tabs are empty, open new tab mode
                    let hasNonEmptyTabs = tabManager.tabs.contains { !$0.isEmpty }
                    if !hasNonEmptyTabs {
                        tabManager.openCommandPaletteForNewTab()
                    } else {
                        tabManager.openCommandPaletteForNavigation()
                    }
                }
                return
            case "t":
                DispatchQueue.main.async {
                    tabManager.openCommandPaletteForNewTab()
                }
                return
            case "k":
                DispatchQueue.main.async {
                    tabManager.openCommandPaletteForTabActions()
                }
                return
            case "w":
                DispatchQueue.main.async {
                    // Defensive check: ensure we have tabs and an active tab before closing
                    guard let activeTab = tabManager.activeTab else {
                        logDebug(.tabManagement, "No valid tab to close")
                        return
                    }
                    tabManager.closeTabUndoably(activeTab)
                }
                return
            case "[":
                DispatchQueue.main.async {
                    tabManager.goBackInCurrentTab()
                }
                return
            case "]":
                DispatchQueue.main.async {
                    tabManager.goForwardInCurrentTab()
                }
                return
            case "r":
                DispatchQueue.main.async {
                    tabManager.reloadCurrentTab()
                }
                return
            case "s":
                DispatchQueue.main.async {
                    sidebarStateManager.toggle()
                }
                return
            case "f":
                DispatchQueue.main.async {
                    findManager?.handleFindShortcut()
                }
                return
            case "+", "=": // Zoom in (Cmd+Plus or Cmd+=)
                DispatchQueue.main.async {
                    tabManager.zoomIn()
                }
                return
            case "-": // Zoom out (Cmd+Minus)
                DispatchQueue.main.async {
                    tabManager.zoomOut()
                }
                return
            case "0": // Reset zoom (Cmd+0)
                DispatchQueue.main.async {
                    tabManager.resetZoom()
                }
                return
            case "g": // CMD+G - Find next
                if let findManager = findManager, findManager.findState.isVisible {
                    DispatchQueue.main.async {
                        findManager.findNext()
                    }
                    return
                }
            default:
                break
            }
        }
        
        // Handle CMD+SHIFT+C to copy current tab URL
        if modifiers == [.command, .shift] && characters == "c" {
            DispatchQueue.main.async {
                tabManager.copyCurrentTabURL()
            }
            return
        }
        
        // Handle CMD+SHIFT+G to find previous
        if modifiers == [.command, .shift] && characters == "g" {
            if let findManager = findManager, findManager.findState.isVisible {
                DispatchQueue.main.async {
                    findManager.findPrevious()
                }
                return
            }
        }
        
        // Handle CMD+OPT+I to toggle web inspector
        if modifiers == [.command, .option] && characters == "i" {
            DispatchQueue.main.async {
                tabManager.toggleWebInspector()
            }
            return
        }
        
        // Handle CMD+OPT+Up/Down for tab navigation
        // Filter out system-added flags (function, numericPad) that come with arrow keys
        if keyCode == 126 || keyCode == 125 { // Up or Down arrows
            let filteredModifiers = modifiers.subtracting([.function, .numericPad])
            if filteredModifiers == [.command, .option] {
                switch keyCode {
                case 125: // Down arrow - the tab below in the sidebar
                    DispatchQueue.main.async {
                        tabManager.navigateToNextTab()
                    }
                    return
                case 126: // Up arrow - the tab above in the sidebar
                    DispatchQueue.main.async {
                        tabManager.navigateToPreviousTab()
                    }
                    return
                default:
                    break
                }
            }
        }
        
        // Handle arrow keys and other keys when command palette is open
        if tabManager.showCommandPalette {
            switch keyCode {
            case 126: // Up arrow
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .commandPaletteUpArrow, object: tabManager)
                }
            case 125: // Down arrow
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .commandPaletteDownArrow, object: tabManager)
                }
            case 36: // Return/Enter
                DispatchQueue.main.async {
                    // Check if command key is pressed and pass that information
                    let isCommandPressed = modifiers.contains(.command)
                    NotificationCenter.default.post(
                        name: .commandPaletteReturn, 
                        object: tabManager,
                        userInfo: ["commandPressed": isCommandPressed]
                    )
                }
            case 53: // Escape
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .commandPaletteEscape, object: tabManager)
                }
            default:
                break
            }
            // The palette's keys are its own: with the find panel open
            // behind it, Return also stepped through matches (in the tab
            // just switched to) and Escape closed both.
            return
        }

        // Handle find panel specific keys
        if let findManager = findManager, findManager.findState.isVisible {
            switch keyCode {
            case 53: // Escape - stop an answer or close Find
                guard !event.isARepeat else { return }
                DispatchQueue.main.async {
                    if findManager.findState.isAnswering {
                        findManager.stopAnswer()
                    } else {
                        findManager.hideFind()
                    }
                }
                return
            case 36: // Return/Enter - find next or previous based on shift
                DispatchQueue.main.async {
                    if modifiers.contains(.shift) {
                        findManager.findPrevious()
                    } else {
                        findManager.findNext()
                    }
                }
                return
            default:
                break
            }
        }
    }
}

// Notification names for command palette navigation. Posted with the
// TabManager of the window whose palette they're for.
extension Notification.Name {
    static let commandPaletteUpArrow = Notification.Name("commandPaletteUpArrow")
    static let commandPaletteDownArrow = Notification.Name("commandPaletteDownArrow")
    static let commandPaletteReturn = Notification.Name("commandPaletteReturn")
    static let commandPaletteUpdateSelection = Notification.Name("commandPaletteUpdateSelection")
    static let commandPaletteRefocus = Notification.Name("commandPaletteRefocus")
    static let commandPaletteEscape = Notification.Name("commandPaletteEscape")
}

