import SwiftUI

struct Shortcut: Identifiable {
    let id = UUID()
    let label: String
    let keys: [Key]
}

enum Key: Hashable {
    case command, option, shift, control
    case character(String)
}

struct KeyCap: View {
    let key: Key
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(symbol(for: key))
          .font(.system(size: 10, weight: .regular, design: .monospaced))
          .foregroundStyle(.secondary.opacity(0.6))
          .frame(width: 18, height: 18, alignment: .center)
          .background(Color.primary.opacity(colorScheme == .dark ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func symbol(for key: Key) -> String {
        switch key {
        case .command:      return "⌘"
        case .option:       return "⌥"
        case .shift:        return "⇧"
        case .control:      return "⌃"
        case .character(let s):
            return s.uppercased()
        }
    }
}

struct Hotkey: View {
    let keys: [Key]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCap(key: key)
            }
        }
        .accessibilityLabel(keysDescription)
    }

    private var keysDescription: String {
        keys.map {
            switch $0 {
            case .command:          return "Command"
            case .option:           return "Option"
            case .shift:            return "Shift"
            case .control:          return "Control"
            case .character(let s): return s.uppercased()
            }
        }.joined(separator: " + ")
    }
}

struct EmptyStateView: View {
    /// What's behind the empty state, in place of a page's color: white in
    /// light mode, black in dark mode
    static let backgroundColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    })

    private let shortcuts: [Shortcut] = [
        .init(label: "New Tab",           keys: [.command, .character("T")]),
        .init(label: "Navigate",          keys: [.command, .character("L")]),
        .init(label: "Toggle Sidebar",    keys: [.command, .character("S")]),
        .init(label: "Copy URL",          keys: [.command, .shift, .character("C")]),
        .init(label: "Open Settings",     keys: [.command, .character(",")])
    ]

    var body: some View {
      VStack(alignment: .center, spacing: 24) {
            Spacer()
        
            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .foregroundColor(Color.primary.opacity(0.3))

            // Hotkeys
            Grid(alignment: .center, horizontalSpacing: 16) {
                GridRow {
                    Color.clear
                    Color.clear
                        .gridColumnAlignment(.leading)
                }
                .gridCellUnsizedAxes([.horizontal, .vertical])

                ForEach(shortcuts) { item in
                    GridRow {
                        Text(item.label)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Hotkey(keys: item.keys)
                            .gridColumnAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    EmptyStateView()
}
