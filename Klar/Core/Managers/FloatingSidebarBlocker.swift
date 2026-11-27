import Foundation
import Combine

/// Lets dialogs that visually "belong" to the floating sidebar (website
/// settings, share picker, Passwords pairing prompt) suspend its auto-hide
/// timers while they are open, so the sidebar can't collapse out from
/// under them. The sidebar resumes its normal hover-driven hide once the
/// last dialog closes. Each window's sidebar on its own: a dialog in one
/// window doesn't hold another's open.
///
/// Callers must run on the main thread — every begin/end site is a UI
/// callback (SwiftUI `.onChange`, `NSPopoverDelegate`, `NSSharingService-
/// PickerDelegate`) so this is naturally satisfied.
final class FloatingSidebarBlocker: ObservableObject {
    static let shared = FloatingSidebarBlocker()

    /// The open dialogs, by the sidebar (SidebarStateManager) they hold open
    @Published private(set) var blockingCounts: [ObjectIdentifier: Int] = [:]

    func isBlocked(_ sidebar: SidebarStateManager) -> Bool {
        blockingCount(of: sidebar) > 0
    }

    func blockingCount(of sidebar: SidebarStateManager) -> Int {
        blockingCounts[ObjectIdentifier(sidebar)] ?? 0
    }

    func beginBlocking(_ sidebar: SidebarStateManager) {
        blockingCounts[ObjectIdentifier(sidebar), default: 0] += 1
    }

    func endBlocking(_ sidebar: SidebarStateManager) {
        let key = ObjectIdentifier(sidebar)
        let count = (blockingCounts[key] ?? 0) - 1
        blockingCounts[key] = count > 0 ? count : nil
    }

    private init() {}
}
