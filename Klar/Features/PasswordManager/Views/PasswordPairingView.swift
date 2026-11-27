import SwiftUI

/// Pairs Klar with the Passwords app for this launch: starts pairing, after
/// which macOS shows a six-digit verification code, and collects that code.
/// Cancels the attempt if it disappears before pairing completes.
struct PasswordPairingView: View {
    @StateObject private var passwordManager = ApplePasswordsManager.shared

    let onPaired: () -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false
    @FocusState private var isCodeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Connect Apple Passwords")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }

                Text(instructions)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            codeField

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
        .task { await startPairing() }
        .onChange(of: passwordManager.state) { _, state in
            if state == .awaitingCode { isCodeFocused = true }
        }
        // No buttons: six digits connect, Escape cancels.
        .onExitCommand {
            passwordManager.cancelPairing()
            onCancel()
        }
        .onDisappear { passwordManager.cancelPairing() }
    }

    /// Six boxes, three and three as Passwords shows the code, over a field
    /// no one sees that takes the typing (and pasting) for them.
    private var codeField: some View {
        let isEnabled = passwordManager.state == .awaitingCode && !isSubmitting
        return ZStack {
            TextField("Verification code", text: $code)
                .textFieldStyle(.plain)
                .focused($isCodeFocused)
                .disabled(!isEnabled)
                .opacity(0)
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue {
                        code = digits
                    } else if digits.count == 6 {
                        submit()
                    }
                }
                .onSubmit(submit)

            HStack(spacing: 12) {
                digitBoxes(0..<3)
                digitBoxes(3..<6)
            }
            .contentShape(.rect)
            .onTapGesture { if isEnabled { isCodeFocused = true } }
            .opacity(isEnabled ? 1 : 0.5)
            .accessibilityHidden(true)
        }
    }

    private func digitBoxes(_ indices: Range<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(indices, id: \.self) { index in
                let digits = Array(code)
                let isCurrent = isCodeFocused && index == min(digits.count, 5)
                ZStack {
                    if index < digits.count {
                        Text(String(digits[index]))
                            .font(.system(size: 18, weight: .medium).monospacedDigit())
                    } else if isCurrent {
                        CodeCaret()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(.quinary, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isCurrent ? 1.5 : 0.5)
                }
            }
        }
    }

    private var instructions: String {
        switch passwordManager.state {
        // The same while Passwords is asked for a code (the boxes are dimmed
        // meanwhile), so the popover doesn't change height as it comes up.
        case .idle, .connecting, .notPaired, .awaitingCode:
            return "Enter the verification code your Mac is showing to use the Passwords app's accounts in Klar."
        case .unavailable(let reason):
            return reason
        case .paired:
            return "Connected."
        }
    }

    private func startPairing() async {
        guard passwordManager.state != .awaitingCode else {
            isCodeFocused = true
            return
        }
        do {
            try await passwordManager.beginPairing()
            if passwordManager.state == .paired { onPaired() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func submit() {
        guard code.count == 6, !isSubmitting, passwordManager.state == .awaitingCode else { return }
        isSubmitting = true
        errorMessage = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await passwordManager.submitCode(code)
                onPaired()
            } catch SRPSession.SessionError.incorrectCode {
                // Passwords drops the attempt on a wrong code; ask for a new one.
                code = ""
                errorMessage = "That code didn't match. Enter the new code Passwords is showing."
                await startPairing()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// The blinking caret in the box the next digit goes into.
private struct CodeCaret: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            RoundedRectangle(cornerRadius: 1)
                .fill(.tint)
                .frame(width: 2, height: 18)
                .opacity(Int(context.date.timeIntervalSinceReferenceDate * 2).isMultiple(of: 2) ? 1 : 0)
        }
    }
}
