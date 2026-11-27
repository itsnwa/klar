import SwiftUI
import AppKit

class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()
    
    @Published var currentAppearance: AppearanceMode = .system {
        didSet {
            applyAppearance()
        }
    }
    
    private init() {
        // Initialize with system appearance
        currentAppearance = .system
        
        // Listen for system appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }
    
    func setAppearance(_ mode: AppearanceMode) {
        guard currentAppearance != mode else { return }
        currentAppearance = mode
    }
    
    private func applyAppearance() {
        DispatchQueue.main.async {
            let previousAppearance = NSApp.appearance
            
            switch self.currentAppearance {
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
                logInfo(.general, "Applied light appearance")
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
                logInfo(.general, "Applied dark appearance")
            case .system:
                NSApp.appearance = nil // Uses system appearance
                logInfo(.general, "Applied system appearance (follows system setting)")
            }
            
            // Log the change if appearance actually changed
            if previousAppearance != NSApp.appearance {
                logInfo(.general, "App appearance changed to: \(self.currentAppearance.rawValue)")
            }
        }
    }
    
    @objc private func systemAppearanceChanged() {
        // Only respond to system changes if we're in system mode
        if currentAppearance == .system {
            applyAppearance()
        }
    }
    
}
