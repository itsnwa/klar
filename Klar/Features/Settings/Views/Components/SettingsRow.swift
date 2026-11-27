import SwiftUI

/// A row of a settings page with a control that has no label of its own
/// (buttons, fields with a button): the title, a subtitle under it, and the
/// control on the trailing edge. Toggles and pickers use their own label
/// instead, `Text(title)` then `Text(subtitle)`, which the form draws the same.
struct SettingsRow<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        LabeledContent {
            content
        } label: {
            Text(title)
            if let subtitle {
                Text(subtitle)
            }
        }
    }
}
