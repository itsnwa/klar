import SwiftUI
import AppKit

/// Which space Settings › Spaces shows. Set by a space's Space Settings…
/// before the window opens, so the page shows that space even when it's
/// built only now.
final class SpaceSettingsSelection: ObservableObject {
    static let shared = SpaceSettingsSelection()
    @Published var spaceID: UUID?
    private init() {}
}

/// Settings › Spaces: a space's name, icon (its letter, or an icomoji),
/// color and separate profile, and deleting it.
struct SpacesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var selection = SpaceSettingsSelection.shared

    @State private var nameDraft = ""
    @FocusState private var isNameFocused: Bool
    /// The name is saved a moment after typing stops, so the space's letter
    /// follows it in the sidebar too.
    @State private var renameTask: Task<Void, Never>?
    @State private var isIconPickerShown = false

    private var selectedSpace: Space? {
        spaceManager.space(withID: selection.spaceID)
            ?? BrowserWindowSession.current.spaceSelection.activeSpace
            ?? spaceManager.spaces.first
    }

    var body: some View {
        SettingsDetailContainer {
            Section {
                spaceChips
            }

            if let space = selectedSpace {
                appearanceGroup(space)
                privacyGroup(space)
            }

        }
        .onAppear {
            nameDraft = selectedSpace?.name ?? ""
        }
        .onChange(of: selectedSpace?.id) { _, _ in
            nameDraft = selectedSpace?.name ?? ""
        }
        .onChange(of: selectedSpace?.name) { _, name in
            if !isNameFocused {
                nameDraft = name ?? ""
            }
        }
    }

    // MARK: - Spaces

    private var spaceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(spaceManager.spaces) { space in
                    let isSelected = space.id == selectedSpace?.id
                    SpaceChip(space: space, name: isSelected ? nameDraft : space.name, isSelected: isSelected) {
                        commitName()
                        selection.spaceID = space.id
                    }
                }

                Button {
                    commitName()
                    selection.spaceID = spaceManager.createSpace()
                } label: {
                    Label("New Space", systemImage: "plus")
                        .font(.system(size: 12))
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Appearance

    private func appearanceGroup(_ space: Space) -> some View {
        Section("Appearance") {
            TextField("Name", text: $nameDraft)
                .focused($isNameFocused)
                .onSubmit { commitName() }
                .onChange(of: nameDraft) { _, _ in
                    scheduleRename()
                }
                .onChange(of: isNameFocused) { _, isFocused in
                    if !isFocused {
                        commitName()
                    }
                }

            SettingsRow(title: "Icon", subtitle: "The first letter of its name, a symbol, an emoji or an icon") {
                Button {
                    isIconPickerShown = true
                } label: {
                    SpaceIconView(icon: space.icon, name: nameDraft, size: 15)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(space.color.color))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .help("Choose an Icon")
                .accessibilityLabel(Text("Icon"))
                .popover(isPresented: $isIconPickerShown, arrowEdge: .bottom) {
                    IcomojiPicker(
                        selection: space.icon.pickerChoice,
                        letter: SpaceIcon.firstLetter(of: nameDraft),
                        tint: space.color.color
                    ) { choice in
                        spaceManager.updateSpace(space.id) { $0.icon = SpaceIcon(choice) }
                    }
                }
            }

            SettingsRow(title: "Color", subtitle: "Tints the sidebar while you’re in this space") {
                HStack(spacing: 8) {
                    ForEach(SpaceColor.allCases) { color in
                        ColorSwatch(color: color, isSelected: color == space.color) {
                            spaceManager.updateSpace(space.id) { $0.color = color }
                        }
                    }
                }
            }
        }
    }

    private func scheduleRename() {
        renameTask?.cancel()
        renameTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitName(keepingEmptyDraft: true)
        }
    }

    /// An empty name puts the old one back, unless typing is still going on.
    private func commitName(keepingEmptyDraft: Bool = false) {
        renameTask?.cancel()
        renameTask = nil
        guard let space = selectedSpace else { return }
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            if !keepingEmptyDraft {
                nameDraft = space.name
            }
        } else if name != space.name {
            spaceManager.renameSpace(space.id, to: name)
        }
    }

    // MARK: - Privacy

    private func privacyGroup(_ space: Space) -> some View {
        Section {
            Toggle(isOn: profileBinding(space)) {
                Text("Separate profile")
                Text(space.usesSeparateProfile
                    ? "Sign-ins, cookies, website data and history in \(space.name) stay in \(space.name)."
                    : "Shares sign-ins, cookies, website data and history with your other spaces.")
            }

            if space.usesSeparateProfile {
                SettingsRow(title: "Website data", subtitle: "Cookies, caches, site storage and history kept for \(space.name)") {
                    Button("Clear Data…") {
                        confirmClearData(space)
                    }
                }
            }
        } header: {
            Text("Privacy")
        } footer: {
            HStack {
                Spacer()
                Button("Delete Space…", role: .destructive) {
                    SpaceActions.confirmDelete(space.id)
                }
                .disabled(!spaceManager.canDeleteSpace(space.id))
            }
        }
    }

    private func profileBinding(_ space: Space) -> Binding<Bool> {
        Binding(
            get: { space.usesSeparateProfile },
            set: { isOn in
                if isOn {
                    spaceManager.setSeparateProfile(true, forSpace: space.id)
                } else {
                    confirmTurnOffProfile(space)
                }
            }
        )
    }

    private func confirmTurnOffProfile(_ space: Space) {
        let alert = NSAlert()
        alert.messageText = "Turn off the separate profile of “\(space.name)”?"
        alert.informativeText = "Its website data and history are deleted, and its tabs reload with the profile your other spaces share."
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) {
            spaceManager.setSeparateProfile(false, forSpace: space.id)
        }
    }

    private func confirmClearData(_ space: Space) {
        let alert = NSAlert()
        alert.messageText = "Clear the website data of “\(space.name)”?"
        alert.informativeText = "You’ll be signed out of websites in this space, and its history is deleted."
        alert.addButton(withTitle: "Clear Data")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        present(alert) {
            spaceManager.clearProfileData(forSpace: space.id)
        }
    }

    private func present(_ alert: NSAlert, onConfirm: @escaping () -> Void) {
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    onConfirm()
                }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            onConfirm()
        }
    }
}

// MARK: - Components

private struct SpaceChip: View {
    let space: Space
    /// The name being typed, for the selected space.
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                SpaceIconView(icon: space.icon, name: name, size: 10)
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(space.color.color))
                Text(name.isEmpty ? space.name : name)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.primary.opacity(isSelected ? 0.12 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0.2 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ColorSwatch: View {
    let color: SpaceColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.swatchColor)
                .frame(width: 18, height: 18)
                .padding(3)
                .overlay(
                    Circle().strokeBorder(color.swatchColor.opacity(isSelected ? 1 : 0), lineWidth: 2)
                )
        }
        .buttonStyle(.plain)
        .help(color.title)
        .accessibilityLabel(Text(color.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
