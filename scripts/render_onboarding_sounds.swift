#!/usr/bin/env swift
// Renders the sounds of first launch's setup (Onboarding) into
// Klar/Assets.xcassets/OnboardingIntro.dataset and OnboardingFinish.dataset.
//
// Both are made here rather than recorded, so they can be tuned in one place:
// filtered noise for air, a low sine sweep for weight, a few soft tones, all
// through AVAudioEngine's own hall reverb, rendered offline.
//
// - Intro: air swells in as the mist drifts in, and the window arrives out of
//   it 1.9 s in with a low thump and a chord blooming open.
// - Finish: a soft whoosh as the window springs to full size, then a long
//   exhale of air as the mist clears away. No notes, which made it sound
//   like a notification.
//
// Usage: swift scripts/render_onboarding_sounds.swift

import AVFoundation
import Foundation

let sampleRate = 48_000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

/// A stereo signal, dry and sent to the reverb
struct Mix {
    var dryLeft: [Float], dryRight: [Float]
    var wetLeft: [Float], wetRight: [Float]

    init(seconds: Double) {
        let count = Int(seconds * sampleRate)
        dryLeft = Array(repeating: 0, count: count)
        dryRight = dryLeft
        wetLeft = dryLeft
        wetRight = dryLeft
    }

    var count: Int { dryLeft.count }

    mutating func add(_ sample: Float, at index: Int, pan: Float, wet: Float) {
        guard index >= 0, index < count else { return }
        // Equal power
        let angle = (pan + 1) * .pi / 4
        let left = sample * cos(angle), right = sample * sin(angle)
        dryLeft[index] += left * (1 - wet)
        dryRight[index] += right * (1 - wet)
        wetLeft[index] += left * wet
        wetRight[index] += right * wet
    }
}

/// The same noise every time
struct Noise {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int64(bitPattern: state >> 11) & 0xFFFFFF) / Float(0x7FFFFF) - 1
    }
}

/// Rises from silence to `peak` over `attack`, then dies away over `release`,
/// both exponentially (as Web Audio's exponential ramps)
func envelope(_ time: Double, peak: Double, attack: Double, release: Double) -> Double {
    let floor = 0.0001
    if time < 0 { return 0 }
    if time < attack { return floor * pow(peak / floor, time / attack) }
    let fall = time - attack
    if fall < release { return peak * pow(floor / peak, fall / release) }
    return 0
}

/// Exponentially from `from` to `peak` over `rise`, then to `to` over `fall`
func sweep(_ time: Double, from: Double, peak: Double, to: Double, rise: Double, fall: Double) -> Double {
    if time < rise { return from * pow(peak / from, max(time, 0) / rise) }
    return peak * pow(to / peak, min((time - rise) / fall, 1))
}

/// Noise through a band-pass filter whose center sweeps, swelling and dying away
func air(_ mix: inout Mix, at start: Double, pan: (Double) -> Double, from: Double, peakFrequency: Double, to: Double,
         gain: Double, rise: Double, fall: Double, q: Double = 0.7, noise: inout Noise) {
    let first = Int(start * sampleRate), length = Int((rise + fall) * sampleRate)
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
    var b0 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    for i in 0..<length {
        let time = Double(i) / sampleRate
        if i % 32 == 0 {
            // RBJ band-pass, 0 dB at the center
            let frequency = sweep(time, from: from, peak: peakFrequency, to: to, rise: rise, fall: fall)
            let w0 = 2 * Double.pi * frequency / sampleRate
            let alpha = sin(w0) / (2 * q)
            let a0 = 1 + alpha
            b0 = alpha / a0
            b2 = -alpha / a0
            a1 = -2 * cos(w0) / a0
            a2 = (1 - alpha) / a0
        }
        let x = Double(noise.next())
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        let level = envelope(time, peak: gain, attack: rise, release: fall)
        mix.add(Float(y * level), at: first + i, pan: Float(pan(time / (rise + fall))), wet: 0.5)
    }
}

/// A soft tone: a sine, or a triangle rounded off by a one-pole low-pass
func tone(_ mix: inout Mix, at start: Double, frequency: Double, triangle: Bool = false, gain: Double,
          attack: Double, release: Double, pan: Double = 0, wet: Double, detuneCents: Double = 0) {
    let first = Int(start * sampleRate), length = Int((attack + release) * sampleRate)
    let hz = frequency * pow(2, detuneCents / 1200)
    var phase = 0.0, smoothed = 0.0
    let smoothing = 1 - exp(-2 * Double.pi * 2400 / sampleRate)
    for i in 0..<length {
        let time = Double(i) / sampleRate
        phase += hz / sampleRate
        phase -= floor(phase)
        var value = triangle ? 4 * abs(phase - 0.5) - 1 : sin(2 * Double.pi * phase)
        if triangle {
            smoothed += (value - smoothed) * smoothing
            value = smoothed
        }
        let level = envelope(time, peak: gain, attack: attack, release: release)
        mix.add(Float(value * level), at: first + i, pan: Float(pan), wet: Float(wet))
    }
}

/// A low sine falling in pitch: the window's weight arriving
func thump(_ mix: inout Mix, at start: Double, from: Double, to: Double, gain: Double) {
    let first = Int(start * sampleRate), length = Int(1.0 * sampleRate)
    var phase = 0.0
    for i in 0..<length {
        let time = Double(i) / sampleRate
        let frequency = from * pow(to / from, min(time / 0.7, 1))
        phase += frequency / sampleRate
        let level = envelope(time, peak: gain, attack: 0.03, release: 0.9)
        mix.add(Float(sin(2 * Double.pi * phase) * level), at: first + i, pan: 0, wet: 0.15)
    }
}

/// The wet signal through the hall, offline
func reverberate(left: [Float], right: [Float], tail: Double) throws -> (left: [Float], right: [Float]) {
    let total = left.count + Int(tail * sampleRate)
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    input.frameLength = AVAudioFrameCount(left.count)
    for i in 0..<left.count {
        input.floatChannelData![0][i] = left[i]
        input.floatChannelData![1][i] = right[i]
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let reverb = AVAudioUnitReverb()
    reverb.loadFactoryPreset(.largeHall2)
    reverb.wetDryMix = 100
    engine.attach(player)
    engine.attach(reverb)
    engine.connect(player, to: reverb, format: format)
    engine.connect(reverb, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()
    player.scheduleBuffer(input)
    player.play()

    var outLeft: [Float] = [], outRight: [Float] = []
    outLeft.reserveCapacity(total)
    outRight.reserveCapacity(total)
    let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    while outLeft.count < total {
        let frames = AVAudioFrameCount(min(4096, total - outLeft.count))
        guard try engine.renderOffline(frames, to: output) == .success else { break }
        for i in 0..<Int(output.frameLength) {
            outLeft.append(output.floatChannelData![0][i])
            outRight.append(output.floatChannelData![1][i])
        }
    }
    engine.stop()
    return (outLeft, outRight)
}

/// Dry and wet together, at `peak` dBFS, faded out over the last half
/// second, as AAC in an .m4a
func write(_ mix: Mix, tail: Double, peak: Double, to url: URL) throws {
    let wet = try reverberate(left: mix.wetLeft, right: mix.wetRight, tail: tail)
    let count = wet.left.count
    var left = wet.left, right = wet.right
    for i in 0..<min(mix.count, count) {
        left[i] += mix.dryLeft[i]
        right[i] += mix.dryRight[i]
    }
    let loudest = zip(left, right).map { max(abs($0), abs($1)) }.max() ?? 1
    let scale = Float(pow(10, peak / 20)) / max(loudest, 0.0001)
    let fade = Int(0.5 * sampleRate)

    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
    buffer.frameLength = AVAudioFrameCount(count)
    for i in 0..<count {
        let out = i > count - fade ? Float(count - i) / Float(fade) : 1
        buffer.floatChannelData![0][i] = left[i] * scale * out
        buffer.floatChannelData![1][i] = right[i] * scale * out
    }

    try? FileManager.default.removeItem(at: url)
    let file = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    try file.write(from: buffer)
    print("Wrote \(url.lastPathComponent) (\(String(format: "%.1f", Double(count) / sampleRate)) s)")
}

let assets = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Klar/Assets.xcassets")
var noise = Noise()

// MARK: - Intro

var intro = Mix(seconds: 5.8)
let start = 0.05
air(&intro, at: start, pan: { -0.6 + 0.84 * $0 }, from: 240, peakFrequency: 2600, to: 700,
    gain: 0.22, rise: 1.8, fall: 2.6, noise: &noise)
air(&intro, at: start + 0.08, pan: { 0.6 - 0.84 * $0 }, from: 300, peakFrequency: 3300, to: 800,
    gain: 0.18, rise: 1.75, fall: 2.7, noise: &noise)
let bloom = start + 1.85
thump(&intro, at: bloom, from: 92, to: 42, gain: 0.45)
// D major with an added ninth's color, strummed upward
let chord: [(Double, Bool, Double)] = [
    (146.83, true, 0.07), (220.00, true, 0.07), (293.66, false, 0.05),
    (369.99, false, 0.05), (440.00, false, 0.05), (554.37, false, 0.05),
]
for (index, note) in chord.enumerated() {
    tone(&intro, at: bloom + Double(index) * 0.035, frequency: note.0, triangle: note.1, gain: note.2,
         attack: 0.2, release: 3.2, pan: Double(index) / 5 - 0.5, wet: 0.55,
         detuneCents: index.isMultiple(of: 2) ? 3 : -3)
}
tone(&intro, at: bloom + 0.3, frequency: 1108.73, gain: 0.012, attack: 0.9, release: 2.6, pan: -0.3, wet: 0.8)
tone(&intro, at: bloom + 0.45, frequency: 1479.98, gain: 0.008, attack: 1.0, release: 2.4, pan: 0.3, wet: 0.85)
try write(intro, tail: 2.8, peak: -4, to: assets.appendingPathComponent("OnboardingIntro.dataset/onboarding-intro.m4a"))

// MARK: - Finish

var finish = Mix(seconds: 4.2)
air(&finish, at: 0.03, pan: { -0.4 + 0.6 * $0 }, from: 1500, peakFrequency: 1100, to: 280,
    gain: 0.2, rise: 0.4, fall: 1.3, q: 0.9, noise: &noise)
// The air clearing, lower and slower, over the mist being pushed away
air(&finish, at: 0.5, pan: { 0.3 - 0.6 * $0 }, from: 380, peakFrequency: 620, to: 180,
    gain: 0.11, rise: 0.9, fall: 2.6, q: 0.6, noise: &noise)
thump(&finish, at: 0.13, from: 66, to: 44, gain: 0.16)
try write(finish, tail: 2.4, peak: -9, to: assets.appendingPathComponent("OnboardingFinish.dataset/onboarding-finish.m4a"))
