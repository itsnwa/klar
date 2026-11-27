import SwiftUI

enum ToastType {
    case success
    case info
    case error
    
    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .success: return .green
        case .info: return .primary.opacity(0.6)
        case .error: return .red
        }
    }
}

struct ToastView: View {
    @ObservedObject var toastManager: ToastManager
    
    init(toastManager: ToastManager) {
        self.toastManager = toastManager
    }
    
    var body: some View {
        // Only there while it shows: glass follows its place in the window,
        // and a hidden toast's was worked out again on every frame of the
        // sidebar sliding in or out
        ZStack {
            if toastManager.isVisible {
                toast
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: toastManager.isVisible)
    }

    private var toast: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: toastManager.icon ?? toastManager.type.icon)
                .foregroundColor(toastManager.type.color)
                .font(.system(size: 12))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(toastManager.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                
                if let description = toastManager.description {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }

            if let action = toastManager.action {
                Button(action.title) {
                    toastManager.dismiss()
                    action.perform()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .semibold))
                .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .spaceGlass(in: RoundedRectangle(cornerRadius: 20))
        .glassEffectTransition(.identity)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
    }
}
