import SwiftUI
import AppKit

// MARK: - Download Animation Overlay

struct DownloadAnimationOverlay: View {
    let icon: NSImage?
    let startPoint: CGPoint
    @State private var animationPhase: AnimationPhase = .start
    
    enum AnimationPhase {
        case start
        case flying
        case complete
    }
    
    var body: some View {
        GeometryReader { geometry in
            if animationPhase != .complete, let icon = icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: 40, height: 40)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    .scaleEffect(animationPhase == .start ? 1.2 : 0.8)
                    .opacity(animationPhase == .start ? 1.0 : 0.3)
                    .position(
                        x: animationPhase == .start ? startPoint.x : 60,
                        y: animationPhase == .start ? startPoint.y : geometry.size.height - 60
                    )
                    .animation(
                        .easeInOut(duration: 0.8),
                        value: animationPhase
                    )
                    .onAppear {
                        animationPhase = .flying
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            animationPhase = .complete
                        }
                    }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}