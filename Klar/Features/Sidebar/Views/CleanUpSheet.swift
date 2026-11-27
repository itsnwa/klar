import SwiftUI

/// Clean Up Saved Tabs… (a space's context menu): pages saved more than once, and saved tabs not opened in
/// months, to tick and remove in one go, with Undo. Every space's and the pinned sites, worked out on this
/// Mac. A header with what was found, the two lists one at a time (a segmented control), each duplicated
/// page a card of its copies, and a bar at the bottom with what Remove will do.
struct CleanUpSheet: View {
    let sidebarManager: SidebarManager
    let onDone: () -> Void

    fileprivate enum Section: Hashable {
        case duplicates, unopened
    }

    fileprivate enum Age: Int, CaseIterable, Identifiable {
        case threeMonths = 3, sixMonths = 6, year = 12
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .threeMonths: return "3 Months"
            case .sixMonths: return "6 Months"
            case .year: return "a Year"
            }
        }
    }

    @State private var section = Section.duplicates
    @State private var structure = SidebarStructure()
    @State private var duplicates: [SavedTabCleanup.DuplicateGroup] = []
    @State private var age = Age.sixMonths
    @State private var unopened: [UUID] = []
    @State private var selected: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 22)
                .padding(.bottom, 18)

            Picker("", selection: $section) {
                Text(duplicates.isEmpty ? "Duplicates" : "Duplicates  \(duplicateCount)").tag(Section.duplicates)
                Text(unopened.isEmpty ? "Not Opened" : "Not Opened  \(unopened.count)").tag(Section.unopened)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .frame(width: 320)
            .padding(.bottom, 14)

            Group {
                switch section {
                case .duplicates: duplicatesList
                case .unopened: unopenedList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bottomBar
        }
        .frame(width: 600, height: 640)
        .onAppear(perform: load)
        .onChange(of: age) { findUnopened() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [.teal, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .shadow(color: .blue.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 6)
            Text("Clean Up Saved Tabs")
                .font(.title2.weight(.semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var summary: String {
        let total = structure.tabs.count
        var parts = [total == 1 ? "1 saved tab" : "\(total) saved tabs"]
        if duplicateCount > 0 {
            parts.append(duplicateCount == 1 ? "1 extra copy" : "\(duplicateCount) extra copies")
        }
        if !unopened.isEmpty {
            parts.append("\(unopened.count) not opened in \(age.title.lowercased())")
        }
        return parts.joined(separator: " · ")
    }

    /// Copies beyond the one each page keeps
    private var duplicateCount: Int {
        duplicates.reduce(0) { $0 + $1.tabIDs.count - 1 }
    }

    // MARK: - Duplicates

    @ViewBuilder
    private var duplicatesList: some View {
        if duplicates.isEmpty {
            ContentUnavailableView(
                "No Duplicates",
                systemImage: "checkmark.seal",
                description: Text("No page is saved more than once.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    Text("The first of each page is kept. Copies are ticked to remove.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    ForEach(duplicates) { group in
                        DuplicateCard(
                            group: group,
                            structure: structure,
                            selected: $selected
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
        }
    }

    // MARK: - Not opened

    @ViewBuilder
    private var unopenedList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("Not opened in")
                    .foregroundStyle(.secondary)
                Picker("", selection: $age) {
                    ForEach(Age.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                if !unopened.isEmpty {
                    let allSelected = selected.isSuperset(of: unopened)
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selected.subtract(unopened)
                        } else {
                            selected.formUnion(unopened)
                        }
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, 28)

            if unopened.isEmpty {
                ContentUnavailableView(
                    "All Opened Lately",
                    systemImage: "clock.badge.checkmark",
                    description: Text("Every saved tab has been opened in the last \(age.title.lowercased()).")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(unopened, id: \.self) { id in
                            CleanUpRow(
                                tabID: id,
                                structure: structure,
                                detail: .lastOpened,
                                badge: nil,
                                isSelected: selectionBinding(id)
                            )
                        }
                    }
                    .padding(6)
                    .background(cardBackground)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .scrollEdgeEffectStyle(.soft, for: .vertical)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            if !selected.isEmpty {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                Text(selected.count == 1 ? "1 tab will be removed" : "\(selected.count) tabs will be removed")
                    .foregroundStyle(.secondary)
                Text("· You can undo this")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Cancel", action: onDone)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
                .controlSize(.large)
            Button(selected.count == 1 ? "Remove 1 Tab" : "Remove \(selected.count) Tabs", action: remove)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(selected.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }

    private func selectionBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: { isOn in
                if isOn { selected.insert(id) } else { selected.remove(id) }
            }
        )
    }

    // MARK: - Finding

    private func load() {
        structure = sidebarManager.sidebarStructure
        duplicates = SavedTabCleanup.duplicates(in: structure)
        // All but the one to keep
        selected = Set(duplicates.flatMap { $0.tabIDs.dropFirst() })
        findUnopened()
        if duplicates.isEmpty && !unopened.isEmpty {
            section = .unopened
        }
    }

    private func findUnopened() {
        let cutoff = Calendar.current.date(byAdding: .month, value: -age.rawValue, to: Date()) ?? Date()
        let duplicated = Set(duplicates.flatMap(\.tabIDs))
        let found = SavedTabCleanup.notOpened(since: cutoff, in: structure).filter { !duplicated.contains($0) }
        // Ticked ones that fall out of the list are left alone
        selected.subtract(Set(unopened).subtracting(found))
        unopened = found
    }

    // MARK: - Removing

    private func remove() {
        let ids = Array(selected)
        let message = ids.count == 1 ? "Removed 1 saved tab" : "Removed \(ids.count) saved tabs"
        sidebarManager.changeUndoably(message) {
            // Pages open meanwhile stay open, as regular tabs
            sidebarManager.removeTabs(withIDs: ids)
        }
        logInfo(.sidebar, "Clean Up removed \(ids.count) saved tabs")
        onDone()
    }
}

// MARK: - Duplicates card

/// A page saved more than once: its icon, title and address, then a row per copy, where it is.
private struct DuplicateCard: View {
    let group: SavedTabCleanup.DuplicateGroup
    let structure: SidebarStructure
    @Binding var selected: Set<UUID>

    var body: some View {
        let first = structure.tabs[group.tabIDs[0]]
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                FaviconView(url: first?.url ?? "", size: 20, cacheOnly: true)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.background))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(first?.displayTitle ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Text(CleanUpRow.shortAddress(first?.url ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text("\(group.tabIDs.count) copies")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ForEach(group.tabIDs, id: \.self) { id in
                let isKept = id == group.tabIDs.first && !selected.contains(id)
                CleanUpRow(
                    tabID: id,
                    structure: structure,
                    detail: .location,
                    badge: isKept ? "Keep" : nil,
                    isSelected: Binding(
                        get: { selected.contains(id) },
                        set: { isOn in
                            if isOn { selected.insert(id) } else { selected.remove(id) }
                        }
                    )
                )
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                )
        )
    }
}

// MARK: - Row

/// A saved tab to keep or remove: a round checkmark, where it is or when it was last opened, and a badge.
private struct CleanUpRow: View {
    enum Detail {
        /// Its space and folders (a copy in a duplicates card)
        case location
        /// Its title, where it is and when it was last opened
        case lastOpened
    }

    let tabID: UUID
    let structure: SidebarStructure
    let detail: Detail
    let badge: String?
    @Binding var isSelected: Bool
    @State private var isHovering = false

    var body: some View {
        let tab = structure.tabs[tabID]
        Button {
            isSelected.toggle()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))

                switch detail {
                case .location:
                    Image(systemName: location.isPinned ? "pin.fill" : "square.stack")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(location.text)
                            .lineLimit(1)
                        Text("Opened \(tab.map { Self.relative($0.lastActiveAt) } ?? "")" + (tab?.customTitle.map { " · Renamed “\($0)”" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                case .lastOpened:
                    FaviconView(url: tab?.url ?? "", size: 16, cacheOnly: true)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab?.displayTitle ?? "")
                            .lineLimit(1)
                        Text(location.text + " · " + Self.shortAddress(tab?.url ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if let badge {
                    Text(badge)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.15)))
                } else if detail == .lastOpened, let tab {
                    Text(Self.relative(tab.lastActiveAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
        )
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .animation(.snappy(duration: 0.2), value: isSelected)
    }

    private var location: (text: String, isPinned: Bool) {
        let text = SavedTabCleanup.location(of: tabID, in: structure)
        return (text, structure.pinnedItems.contains(tabID))
    }

    /// "example.com/path", without the scheme or `www.`
    static func shortAddress(_ address: String) -> String {
        guard let components = URLComponents(string: address), var host = components.host else { return address }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + (components.path == "/" ? "" : components.path)
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
