import SwiftUI
import Combine

/// A toast's button and what it does.
struct ToastAction {
    let title: String
    let perform: () -> Void
}

class ToastManager: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var message: String = ""
    @Published var description: String? = nil
    @Published var type: ToastType = .info
    @Published var icon: String? = nil
    /// A button on the toast, such as Undo
    @Published var action: ToastAction? = nil
    
    private var timer: Timer?
    
    func showToast(message: String, description: String? = nil, type: ToastType = .info, icon: String? = nil,
                   action: ToastAction? = nil, duration: TimeInterval = 2.0) {
        // Ensure we're on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Cancel any existing timer
            self.timer?.invalidate()
            
            // Update message, description, type, and icon
            self.message = message
            self.description = description
            self.type = type
            self.icon = icon
            self.action = action
            
            // Show toast
            withAnimation(.spring(response: 0.4, dampingFraction: 0.35)) {
                self.isVisible = true
            }
            
            // Auto-dismiss after duration
            self.timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.35)) {
                        self.isVisible = false
                    }
                }
            }
        }
    }

    /// Hides it at once, as its button is pressed
    func dismiss() {
        timer?.invalidate()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.35)) {
            isVisible = false
        }
        action = nil
    }
    
    isolated deinit {
        timer?.invalidate()
    }
} 
