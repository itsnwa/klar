import SwiftUI

/// Klar › Check for Updates… (Restart to Update once an update's ready) and What's New…, after About Klar.
/// Debug builds can also simulate an update and show first launch's setup again.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: .shared)
            #if DEBUG
            Button("Simulate an Update") { AppUpdater.shared.simulateUpdate() }
            Button("Show Onboarding") { Onboarding.shared.showInNewWindow() }
            #endif
            Button("What’s New…") { WhatsNew.shared.showMenuNotes() }
                .disabled(WhatsNew.menuNotes == nil)
        }
    }
}

/// A view of its own so it follows the updater: the App's commands don't observe it.
struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        if updater.readyUpdate != nil {
            Button("Restart to Update") { updater.installUpdate() }
        } else {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
