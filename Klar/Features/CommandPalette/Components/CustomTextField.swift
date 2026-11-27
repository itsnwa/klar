import SwiftUI
import AppKit

// MARK: - Custom TextField with Auto-completion
struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onChange: ((String) -> Void)?
    let onBackspaceWithSelection: (() -> Void)?
    /// What the palette's notifications to and from the field are posted
    /// with: its window's TabManager, so another window's palette doesn't
    /// take them
    let notificationScope: AnyObject?
    
    init(text: Binding<String>, placeholder: String, isFocused: FocusState<Bool>.Binding, notificationScope: AnyObject? = nil, onSubmit: @escaping () -> Void, onChange: ((String) -> Void)? = nil, onBackspaceWithSelection: (() -> Void)? = nil) {
        self._text = text
        self.placeholder = placeholder
        self._isFocused = isFocused
        self.notificationScope = notificationScope
        self.onSubmit = onSubmit
        self.onChange = onChange
        self.onBackspaceWithSelection = onBackspaceWithSelection
    }
    
    func makeNSView(context: Context) -> WhiteCaretTextField {
        let textField = WhiteCaretTextField()
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear
        textField.font = NSFont.systemFont(ofSize: 16)
        textField.textColor = NSColor.labelColor
        textField.focusRingType = .none
        textField.drawsBackground = false
        textField.bezelStyle = .roundedBezel
        textField.isBezeled = false

        // Ensure single line input only
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.maximumNumberOfLines = 1

        context.coordinator.textField = textField
        context.coordinator.parent = self

        // Listen for forced text selection notification. Capture the field
        // weakly and store the token on the coordinator so dismantleNSView
        // can drop the observer — otherwise the closure (which strongly
        // captures `textField`) outlives every CommandPalette open/close
        // cycle (the palette uses `.id(...)` to force-recreate the view).
        context.coordinator.forceSelectionObserver = NotificationCenter.default.addMainObserver(
            forName: NSNotification.Name("ForceTextSelection"),
            object: notificationScope
        ) { [weak textField] _ in
            textField?.forceFocusAndSelect()
        }

        return textField
    }

    static func dismantleNSView(_ nsView: WhiteCaretTextField, coordinator: Coordinator) {
        if let token = coordinator.forceSelectionObserver {
            NotificationCenter.default.removeObserver(token)
            coordinator.forceSelectionObserver = nil
        }
    }
    
    func updateNSView(_ nsView: WhiteCaretTextField, context: Context) {
        context.coordinator.parent = self
        
        // Update text field with current text and handle selection
        let textChanged = nsView.stringValue != text
        if textChanged {
            nsView.stringValue = text
        }
        
        // Update placeholder attributes only if needed
        if let placeholderCell = nsView.cell as? NSTextFieldCell,
           placeholderCell.placeholderAttributedString?.string != placeholder {
            let placeholderAttributes: [NSAttributedString.Key: Any] = [
              .foregroundColor: NSColor.secondaryLabelColor,
              .font: NSFont.systemFont(ofSize: 16)
            ]
            placeholderCell.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: placeholderAttributes
            )
        }
        
        // Handle focus state changes. While it's edited, the first responder
        // is the field editor, not the field.
        if isFocused && nsView.currentEditor() == nil {
            // Only attempt focus if we're not already focused and view is ready
            if nsView.superview?.isHidden == false {
                nsView.forceFocusAndSelect()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CustomTextField
        weak var textField: WhiteCaretTextField?
        var forceSelectionObserver: NSObjectProtocol?

        init(_ parent: CustomTextField) {
            self.parent = parent
        }

        isolated deinit {
            if let token = forceSelectionObserver {
                NotificationCenter.default.removeObserver(token)
            }
        }
        
        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                DispatchQueue.main.async {
                    let newText = textField.stringValue
                    
                    // Always update if different
                    if newText != self.parent.text {
                        self.parent.text = newText
                        self.parent.onChange?(newText)
                    }
                }
            }
        }
        
        func controlTextDidBeginEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
            
            if let textView = obj.userInfo?["NSFieldEditor"] as? NSTextView {
                textView.insertionPointColor = NSColor.textColor
                textView.typingAttributes = [
                    .foregroundColor: NSColor.labelColor,
                    .font: NSFont.systemFont(ofSize: 16)
                ]
            }
        }
        
        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) ||
               commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                // Check if command key is pressed and store that information
                let isCommandPressed = NSEvent.modifierFlags.contains(.command)
                
                // Post notification about command key state before submitting
                NotificationCenter.default.post(
                    name: NSNotification.Name("CommandPaletteSubmit"),
                    object: parent.notificationScope,
                    userInfo: ["commandPressed": isCommandPressed]
                )
                
                parent.onSubmit()
                return true
            } else if commandSelector == #selector(NSResponder.deleteBackward(_:)) {
                if parent.text.isEmpty && textView.string.isEmpty {
                    // Handle backspace on completely empty field
                    DispatchQueue.main.async {
                        self.parent.onBackspaceWithSelection?()
                    }
                    return true
                }
            } else if commandSelector == #selector(NSResponder.insertParagraphSeparator(_:)) {
                // Prevent any multi-line input
                return true
            }
            return false
        }
    }
}

// MARK: - Custom TextField with White Caret
class WhiteCaretTextField: NSTextField {
    private var keyMonitor: Any?
    private var lastCommandKeyState = false
    /// Something was typed: focusing it again mustn't select that, which the
    /// next key would replace.
    private var hasBeenTypedIn = false
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTextField()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextField()
    }
    
    isolated deinit {
        stopKeyMonitoring()
    }
    
    private func setupTextField() {
        focusRingType = .none
        drawsBackground = false
        isBordered = false
        isBezeled = false
        
        // Ensure single line behavior
        cell?.wraps = false
        cell?.isScrollable = true
        maximumNumberOfLines = 1
    }
    
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            setupWhiteCaret()
            startKeyMonitoring()
            
            // Select all text when becoming first responder, but only if we have content
            if !stringValue.isEmpty {
                if let textView = self.currentEditor() as? NSTextView {
                    textView.selectAll(nil)
                } else {
                    self.selectText(nil)
                }
            }
        }
        return result
    }
    
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            stopKeyMonitoring()
        }
        return result
    }
    
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        setupWhiteCaret()
    }

    override func textDidChange(_ notification: Notification) {
        // Only edits in the field editor, not text set from the palette
        hasBeenTypedIn = true
        super.textDidChange(notification)
    }

    /// Keys typed right as the palette opens go to it, not to the page.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, window.isKeyWindow {
            _ = window.makeFirstResponder(self)
        }
    }

    private var isBeingEdited: Bool {
        guard let editor = currentEditor() else { return false }
        return window?.firstResponder === editor
    }
    
    func forceFocus() {
        isEnabled = true
        isHidden = false
        isEditable = true
        isSelectable = true
        
        if let window = self.window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            
            if !window.makeFirstResponder(self) {
                _ = self.becomeFirstResponder()
            }
        }
    }
    
    func forceFocusAndSelect() {
        // Ensure window is ready
        guard let window = self.window else { return }

        // Already focused: select the text set from the palette (a page's
        // address), but not what's been typed
        if isBeingEdited {
            if !hasBeenTypedIn, !stringValue.isEmpty {
                currentEditor()?.selectAll(nil)
            }
            return
        }
        
        // Make window key if needed
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }
        
        // Force focus
        forceFocus()
        
        // Wait for focus to be established before attempting text selection
        DispatchQueue.main.async {
            // Verify we became first responder before selecting text
            if self.isBeingEdited && !self.hasBeenTypedIn && !self.stringValue.isEmpty {
                if let textView = self.currentEditor() as? NSTextView {
                    textView.selectAll(nil)
                } else {
                    self.selectText(nil)
                }
            }
            
            // Ensure key monitoring is active
            self.startKeyMonitoring()
        }
    }
    
    private func setupWhiteCaret() {
        DispatchQueue.main.async {
            if let textView = self.currentEditor() as? NSTextView {
                textView.insertionPointColor = NSColor.textColor
                textView.selectedTextAttributes = [
                    .backgroundColor: NSColor.selectedTextBackgroundColor,
                    .foregroundColor: NSColor.selectedTextColor
                ]
            }
        }
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Ensure no focus ring is drawn
    }
    
    private func startKeyMonitoring() {
        stopKeyMonitoring() // Ensure no duplicate monitors
        
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        
        // Check initial state
        let currentCommandState = NSEvent.modifierFlags.contains(.command)
        if currentCommandState != lastCommandKeyState {
            lastCommandKeyState = currentCommandState
            NotificationCenter.default.post(
                name: NSNotification.Name("CommandKeyStateChanged"),
                object: currentCommandState
            )
        }
    }
    
    private func stopKeyMonitoring() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        
        // Reset command key state when stopping monitoring
        if lastCommandKeyState {
            lastCommandKeyState = false
            NotificationCenter.default.post(
                name: NSNotification.Name("CommandKeyStateChanged"),
                object: false
            )
        }
    }
    
    private func handleFlagsChanged(_ event: NSEvent) {
        let currentCommandState = event.modifierFlags.contains(.command)
        if currentCommandState != lastCommandKeyState {
            lastCommandKeyState = currentCommandState
            NotificationCenter.default.post(
                name: NSNotification.Name("CommandKeyStateChanged"),
                object: currentCommandState
            )
        }
    }
}

// MARK: - Custom NSTextView with Wide White Caret
class WideCaretTextView: NSTextView {
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if flag {
            let widerRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: 4.0, height: rect.height)
            NSColor.white.set()
            widerRect.fill()
        }
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        insertionPointColor = NSColor.white
    }
} 
