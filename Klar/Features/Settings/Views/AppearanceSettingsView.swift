import SwiftUI

struct AppearanceSettingsView: View {
    @StateObject private var settingsManager = TOMLSettingsManager.shared

    var body: some View {
        SettingsDetailContainer {
            Section {
                LabeledContent("Appearance") {
                    AppearancePicker(selection: $settingsManager.appearanceMode)
                }
            }

            Section("Window") {
                Toggle(isOn: $settingsManager.insetWebView) {
                    Text("Inset web pages")
                    Text("Leave a small frame around the page")
                }
            }
        }
    }
}

/// Light, Dark and System as thumbnails of windows on a desktop, as in
/// System Settings › Appearance.
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(AppearanceMode.allCases, id: \.self) { mode in
                let isSelected = mode == selection
                Button {
                    selection = mode
                } label: {
                    VStack(spacing: 5) {
                        AppearanceThumbnail(mode: mode)
                            .padding(3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.accentColor.opacity(isSelected ? 1 : 0), lineWidth: 3)
                            )
                        Text(mode.rawValue)
                            .font(.callout)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(mode.rawValue))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// A picture of Klar in that appearance, from the asset catalog
/// (`appearance-light`, `appearance-dark`; System shows half of each), or a
/// drawn window on a desktop while there's none.
private struct AppearanceThumbnail: View {
    let mode: AppearanceMode

    var body: some View {
        Group {
            switch mode {
            case .light:
                scene(isDark: false)
            case .dark:
                scene(isDark: true)
            case .system:
                // Light on the leading half, dark on the trailing one.
                scene(isDark: false)
                    .overlay {
                        scene(isDark: true)
                            .mask {
                                HStack(spacing: 0) {
                                    Color.clear
                                    Color.black
                                }
                            }
                    }
            }
        }
        .frame(width: 112, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func scene(isDark: Bool) -> some View {
        if let image = NSImage(named: isDark ? "appearance-dark" : "appearance-light") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 112, height: 70, alignment: .topLeading)
        } else {
            AppearanceThumbnailScene(isDark: isDark)
                .scaleEffect(112 / 72, anchor: .topLeading)
                .frame(width: 112, height: 70, alignment: .topLeading)
        }
    }
}

/// A desktop with a window and its sidebar's selected row behind, and a
/// window with its window buttons in front.
private struct AppearanceThumbnailScene: View {
    let isDark: Bool

    private var desktop: [Color] {
        isDark
            ? [Color(red: 0.17, green: 0.22, blue: 0.55), Color(red: 0.04, green: 0.07, blue: 0.24)]
            : [Color(red: 0.83, green: 0.91, blue: 1.0), Color(red: 0.36, green: 0.6, blue: 0.97)]
    }

    private var surface: Color {
        isDark ? Color(white: 0.15) : .white
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: desktop, startPoint: .topLeading, endPoint: .bottomTrailing)

            RoundedRectangle(cornerRadius: 3)
                .fill(surface)
                .frame(width: 46, height: 26)
                .overlay(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 28, height: 5)
                        .padding(4)
                }
                .offset(x: 6, y: 6)

            RoundedRectangle(cornerRadius: 4)
                .fill(surface)
                .frame(width: 40, height: 24)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 2.5) {
                        Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                        Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18))
                        Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
                    }
                    .frame(height: 4.5)
                    .padding(5)
                }
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .offset(x: 26, y: 26)
        }
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 700, height: 500)
}
