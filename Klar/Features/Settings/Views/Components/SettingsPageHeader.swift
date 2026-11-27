import SwiftUI

/// The card General opens with, as in System Settings: Klar's icon, its
/// version and update status, centered. Its `accessory` goes under them (the
/// update button).
struct SettingsPageHeader<Icon: View, Accessory: View>: View {
    let title: String
    let summary: String
    @ViewBuilder let icon: Icon
    @ViewBuilder let accessory: Accessory

    var body: some View {
        Section {
            VStack(spacing: 6) {
                icon
                    .padding(.bottom, 4)
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                accessory
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }
}
