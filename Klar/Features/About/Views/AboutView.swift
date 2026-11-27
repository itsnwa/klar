import SwiftUI

/// About Klar's content (`AboutWindowController`): the icon, name, version and tagline, buttons to Klar's website
/// and its source on GitHub, which open in a tab, and links to the acknowledgements and the license
/// (`AcknowledgementsPage`) above the copyright from Info.plist.
struct AboutView: View {
    static let website = "https://klarbrowser.com"
    static let sourceCode = "https://github.com/itsnwa/klar"

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            Text("Klar")
                .font(.system(size: 26, weight: .semibold))
                .padding(.top, 14)

            Text("Version \(Bundle.main.shortVersion)")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("A calm, fast web browser for the Mac.")
                .multilineTextAlignment(.center)
                .padding(.top, 18)

            HStack(spacing: 10) {
                Button {
                    Self.open(Self.website)
                } label: {
                    Label("Website", systemImage: "globe")
                }
                Button {
                    Self.open(Self.sourceCode)
                } label: {
                    Label {
                        Text("GitHub")
                    } icon: {
                        Image("brand-github")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                    }
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .padding(.top, 24)

            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Button("Acknowledgements") { AcknowledgementsPage.show() }
                    Button("License") { AcknowledgementsPage.show(section: "klar") }
                }
                .buttonStyle(.link)
                .font(.callout)

                Text(Bundle.main.copyright)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)
        }
        .padding(.horizontal, 36)
        .padding(.top, 48)
        .padding(.bottom, 28)
        .frame(width: 340)
        .ignoresSafeArea()
    }

    /// In a new tab in the browser window in front.
    private static func open(_ address: String) {
        BrowserWindow.perform { _ = $0.tabManager.createNewTab(url: address) }
    }
}

extension Bundle {
    /// Info.plist's copyright line, as About Klar and Finder show it.
    var copyright: String {
        object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? ""
    }
}
