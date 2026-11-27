import Foundation

// MARK: - Tab Media State

class TabMediaState: ObservableObject {
    @Published var isPlayingMedia: Bool = false
    @Published var isMediaMuted: Bool = false
    @Published var isMediaPaused: Bool = false
    @Published var lastDetectionTime: Date = Date()

    /// Whether this tab has active media (playing, paused, or muted)
    var hasActiveMedia: Bool {
        isPlayingMedia || isMediaPaused || isMediaMuted
    }

    func updatePlaybackState(_ isPlaying: Bool) {
        if isPlayingMedia != isPlaying {
            // When media resumes playing, clear the paused flag
            if isPlaying {
                isMediaPaused = false
            }
            isPlayingMedia = isPlaying
            lastDetectionTime = Date()
        }
    }
    
    func updateMuteState(_ isMuted: Bool) {
        if isMediaMuted != isMuted {
            isMediaMuted = isMuted
            lastDetectionTime = Date()
        }
    }
}
