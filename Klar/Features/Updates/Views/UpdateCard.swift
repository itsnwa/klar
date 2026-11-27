import SwiftUI

/// The update in the sidebar, above the space bar: the answer to Check for Updates…, an update's download,
/// and Restart to Update once it's ready (`AppUpdater`). Every window's sidebar shows it. Closed, it's hidden
/// until Klar opens again; the update still installs when Klar quits, and the command palette still offers it.
/// A silent update (`AppUpdater.Update.isSilent`) doesn't show it.
/// Observes the updater alone, so its progress re-runs nothing else.
///
/// It comes into focus as it rises from the space bar, and goes out of focus as it sinks back
/// (`UpdateCardTransition`). Its steps (the download, then Restart to Update) change on the same spring, in a
/// transaction of their own (`withAnimation`), so the sidebar's content above makes room with it rather than
/// jumping.
struct UpdateCard: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var isHovering = false
    /// The step on screen, which follows the updater's with an animation.
    @State private var shownPhase: Phase = .hidden
    /// What the card says: the updater's state, or the last one it had while the card goes away.
    @State private var content: AppUpdater.State = .idle

    /// The card's steps: a change of one is animated, the download's progress isn't.
    private enum Phase {
        case hidden, checking, answer, downloading, preparing, ready, installing

        init(_ state: AppUpdater.State, isHidden: Bool) {
            guard !isHidden, state.update?.isSilent != true else {
                self = .hidden
                return
            }
            self = switch state {
            case .idle: .hidden
            case .checking: .checking
            case .upToDate, .failed: .answer
            case .downloading: .downloading
            case .preparing: .preparing
            case .ready: .ready
            case .installing: .installing
            }
        }
    }

    /// "12.0 MB", never "12 MB", "512 KB" or "Zero KB": a size that keeps its shape as the download counts up.
    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.zeroPadsFractionDigits = true
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    /// In on a spring with a little give, out quicker.
    private static let appear = Animation.spring(response: 0.5, dampingFraction: 0.8)
    private static let disappear = Animation.easeIn(duration: 0.22)

    var body: some View {
        VStack(spacing: 0) {
            if shownPhase != .hidden {
                card
                    .transition(UpdateCardTransition())
            }
        }
        .onAppear {
            // A window opening while there's an update shows it as it is
            content = updater.state
            shownPhase = Phase(updater.state, isHidden: updater.isCardHidden)
        }
        .onChange(of: updater.state) { follow() }
        .onChange(of: updater.isCardHidden) { follow() }
    }

    private func follow() {
        let state = updater.state
        let phase = Phase(state, isHidden: updater.isCardHidden)
        guard phase != shownPhase else {
            // The download's progress
            if state != .idle {
                content = state
            }
            return
        }
        withAnimation(phase == .hidden ? Self.disappear : Self.appear) {
            if state != .idle {
                content = state
            }
            shownPhase = phase
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                icon
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            // The download's sizes keep their width as they count up
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                // Room for the close button in the corner
                Spacer(minLength: canClose ? 18 : 0)
            }
            switch content {
            case .downloading(_, let received, let expected):
                ProgressView(value: expected > 0 ? min(Double(received) / Double(expected), 1) : 0)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .transition(.blurReplace)
            case .preparing:
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .transition(.blurReplace)
            case .ready:
                Button {
                    updater.installUpdate()
                } label: {
                    Text("Restart to Update")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .help("Klar quits, installs the update and opens again")
                .transition(.blurReplace)
            default:
                EmptyView()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        .overlay(alignment: .topTrailing) {
            if canClose {
                closeButton
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .padding(7)
            }
        }
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var icon: some View {
        switch content {
        case .checking:
            ProgressView()
                .controlSize(.small)
                .transition(.blurReplace)
        case .upToDate:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.green)
                .transition(.blurReplace)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .transition(.blurReplace)
        default:
            Image("logo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.primary)
                .frame(width: 15, height: 15)
                .transition(.blurReplace)
        }
    }

    private var title: String {
        switch content {
        case .idle, .checking: "Checking for Updates…"
        case .upToDate: "Klar is up to date"
        case .failed(let title, _): title
        case .downloading(let update, _, _): "Downloading \(update.name)"
        case .preparing(let update): "Preparing \(update.name)"
        case .ready(let update): "\(update.name) is ready"
        case .installing: "Restarting…"
        }
    }

    private var subtitle: String? {
        switch content {
        case .idle, .checking, .preparing:
            return nil
        case .upToDate:
            return "\(Bundle.main.shortVersion) is the newest version"
        case .failed(_, let message):
            return message
        case .downloading(_, let received, let expected):
            guard expected > 0 else { return nil }
            let total = Self.sizeFormatter.string(fromByteCount: Int64(expected))
            let done = Self.sizeFormatter.string(fromByteCount: Int64(min(received, expected)))
            return "\(done) of \(total)"
        case .ready(let update):
            return update.headline.map { "New: \($0)" } ?? "Restart Klar to install it"
        case .installing(let update):
            return update.version.map { "Klar opens again on \($0)" }
        }
    }

    /// Not while it's checking or restarting, which are over in a moment.
    private var canClose: Bool {
        switch content {
        case .checking, .installing: false
        default: true
        }
    }

    private var closeButton: some View {
        Button {
            updater.isCardHidden = true
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Hide until Klar opens again. The update installs when you quit Klar.")
        .accessibilityLabel("Hide")
    }
}

/// Out of focus, a little smaller and lower, from the bottom edge, where the space bar is: the card sharpens
/// as it rises into place, and blurs as it sinks away. The fade only finishes the blur's work.
private struct UpdateCardTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.9, anchor: .bottom)
            .offset(y: phase.isIdentity ? 0 : 12)
            .blur(radius: phase.isIdentity ? 0 : 10)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}
