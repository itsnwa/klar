import SwiftUI

struct FeatureFlagsSettingsView: View {
    @StateObject private var manager = FeatureFlagsManager.shared
    @State private var search: String = ""
    @State private var showingResetConfirm = false

    private var filteredGroups: [(category: String, features: [WebKitFeature])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return WebKitFeatureRegistry.byCategory }
        return WebKitFeatureRegistry.byCategory.compactMap { group in
            let filtered = group.features.filter {
                $0.name.lowercased().contains(query)
                    || $0.key.lowercased().contains(query)
                    || group.category.lowercased().contains(query)
                    || $0.details.lowercased().contains(query)
            }
            return filtered.isEmpty ? nil : (group.category, filtered)
        }
    }

    private var unknownKeys: [String] {
        manager.unknownOverrideKeys()
    }

    var body: some View {
        VStack(spacing: 0) {
            featureList
            Divider()
            footer
        }
        .searchable(text: $search, prompt: "Search features")
        .confirmationDialog(
            "Reset all WebKit feature flag overrides?",
            isPresented: $showingResetConfirm,
            titleVisibility: .visible
        ) {
            Button("Reset Feature Flags", role: .destructive) {
                manager.resetAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Toggles will return to WebKit's defaults. Your config.toml [feature_flags] section will be cleared.")
        }
    }

    @ViewBuilder
    private var featureList: some View {
        if WebKitFeatureRegistry.allFeatures.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundColor(.orange)
                Text("WebKit feature SPI unavailable")
                    .font(.headline)
                Text("Klar couldn't enumerate WebKit features. Check the Console for details.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // ~600 flags: a grouped Form builds every row before the page
            // shows (over a second), so this draws the form's cards itself in
            // a lazy stack that builds only the rows on screen.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !unknownKeys.isEmpty {
                        sectionHeader("Unknown overrides in your TOML")
                        ForEach(Array(unknownKeys.enumerated()), id: \.element) { index, key in
                            HStack(alignment: .titleLine, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key)
                                        .monospaced()
                                        .alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
                                    Text("This key isn't recognized by the current WebKit. It was likely renamed or removed.")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Remove") {
                                    manager.setOverride(key, enabled: nil)
                                }
                            }
                            .modifier(FormCardRow(isFirst: index == 0, isLast: index == unknownKeys.count - 1))
                        }
                    }

                    ForEach(filteredGroups, id: \.category) { group in
                        sectionHeader(group.category)
                        ForEach(Array(group.features.enumerated()), id: \.element.id) { index, feature in
                            FeatureFlagRow(feature: feature, manager: manager)
                                .modifier(FormCardRow(isFirst: index == 0, isLast: index == group.features.count - 1))
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.horizontal, 10)
            .padding(.top, 30)
            .padding(.bottom, 10)
    }

    private var footer: some View {
        HStack {
            Text("\(WebKitFeatureRegistry.allFeatures.count) features · \(manager.overrides.count) overridden")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button(role: .destructive) {
                showingResetConfirm = true
            } label: {
                Text("Reset Feature Flags")
            }
            .disabled(manager.overrides.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct FeatureFlagRow: View {
    let feature: WebKitFeature
    @ObservedObject var manager: FeatureFlagsManager

    private var binding: Binding<Bool> {
        Binding(
            get: { manager.effectiveValue(for: feature) },
            set: { newValue in
                if newValue == feature.defaultValue {
                    manager.setOverride(feature.key, enabled: nil)
                } else {
                    manager.setOverride(feature.key, enabled: newValue)
                }
            }
        )
    }

    var body: some View {
        HStack(alignment: .titleLine, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(feature.name)
                        .font(.body)
                    if manager.isOverridden(feature.key) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundColor(.accentColor)
                            .help("Overridden from WebKit default")
                    }
                }
                .alignmentGuide(.titleLine) { $0[VerticalAlignment.center] }
                if !feature.details.isEmpty {
                    Text(feature.details)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(feature.key)
                    .font(.caption2)
                    .monospaced()
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            StatusBadge(status: feature.status)
            // A grouped Form's switch.
            Toggle(feature.name, isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// A row of a card drawn like a grouped Form's: the card's background, its
/// corners on the first and last row, and a separator between rows.
private struct FormCardRow: ViewModifier {
    let isFirst: Bool
    let isLast: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                if !isFirst {
                    Divider().padding(.horizontal, 10)
                }
            }
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: isFirst ? 10 : 0,
                    bottomLeadingRadius: isLast ? 10 : 0,
                    bottomTrailingRadius: isLast ? 10 : 0,
                    topTrailingRadius: isFirst ? 10 : 0
                )
                .fill(Color(nsColor: .quaternarySystemFill))
            )
    }
}

private extension VerticalAlignment {
    /// The middle of a row's title line, which its controls line up with.
    enum TitleLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let titleLine = VerticalAlignment(TitleLine.self)
}

private struct StatusBadge: View {
    let status: WebKitFeature.Status

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .foregroundColor(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status.color.opacity(0.15))
            .clipShape(Capsule())
    }
}

#Preview {
    FeatureFlagsSettingsView()
        .frame(width: 700, height: 600)
}
