import SwiftUI

/// A settings page: a grouped form, as in System Settings. Its sections are
/// the cards, each `Section`'s header the title above one. The toolbar gets
/// its background only once the page scrolls under it: the default scroll
/// edge effect (a `.hard` one shows it at the top too).
struct SettingsDetailContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form {
            content
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsDetailContainer {
        Section("Section") {
            Text("Content goes here")
        }
    }
    .frame(width: 600, height: 400)
}
