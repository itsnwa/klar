import AppKit
import AVFoundation

/// The setup's two sounds, made by scripts/render_onboarding_sounds.swift:
/// the window arriving out of the mist, and growing into the browser. Only
/// with System Settings › Sound › Play user interface sound effects on.
enum OnboardingSound: String {
    case intro = "OnboardingIntro"
    case finish = "OnboardingFinish"

    /// Held while they play
    private static var players: [OnboardingSound: AVAudioPlayer] = [:]

    func play() {
        guard Self.playsInterfaceSounds,
              let data = NSDataAsset(name: rawValue)?.data,
              let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.m4a.rawValue) else { return }
        player.volume = 0.8
        player.play()
        Self.players[self] = player
    }

    /// Unset until it's turned off
    private static var playsInterfaceSounds: Bool {
        UserDefaults.standard.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }
}
