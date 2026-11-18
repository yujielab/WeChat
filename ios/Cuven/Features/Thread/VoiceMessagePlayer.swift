import Foundation
import AVFoundation
import CoreGraphics
import Observation

// MARK: - Voice Message Waveform & Playback Engine

@MainActor
@Observable
final class VoiceMessagePlayer {
    private(set) var activeMessageID: String?
    private(set) var isPlaying: Bool = false
    private(set) var progressByMessage: [String: Double] = [:]

    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var progressTask: Task<Void, Never>?
    private var currentDuration: Double = 1.0

    func progress(for messageID: String) -> Double {
        progressByMessage[messageID] ?? 0
    }

    func isPlayingMessage(_ messageID: String) -> Bool {
        activeMessageID == messageID && isPlaying
    }

    func togglePlayback(
        messageID: String,
        mediaURLString: String?,
        serverBaseURL: URL,
        fallbackDuration: Double
    ) {
        if activeMessageID == messageID && isPlaying {
            pause()
            return
        }

        stop()
        activeMessageID = messageID
        currentDuration = max(1.0, fallbackDuration)

        configurePlaybackSession()

        if let raw = mediaURLString?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if raw.hasPrefix("data:audio"),
               let comma = raw.firstIndex(of: ","),
               let data = Data(base64Encoded: String(raw[raw.index(after: comma)...]), options: .ignoreUnknownCharacters),
               let player = try? AVAudioPlayer(data: data)
            {
                startLocalAudioPlayer(player, for: messageID)
                return
            }

            let resolvedURL: URL? = {
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") || raw.hasPrefix("file://") {
                    return URL(string: raw)
                } else if raw.hasPrefix("/") {
                    return URL(string: raw, relativeTo: serverBaseURL)?.absoluteURL
                }
                return URL(string: raw)
            }()

            if let url = resolvedURL {
                if url.isFileURL, let player = try? AVAudioPlayer(contentsOf: url) {
                    startLocalAudioPlayer(player, for: messageID)
                    return
                } else if !url.isFileURL {
                    startRemoteStreamPlayer(url: url, for: messageID, fallbackDuration: currentDuration)
                    return
                }
            }
        }

        // Offline / Demo seed voice message fallback: synthesize a warm playable 16kHz WAV chord in memory
        let synthesizedWAV = Self.makePlayableVoicePreviewWAV(durationSeconds: currentDuration)
        if let player = try? AVAudioPlayer(data: synthesizedWAV) {
            startLocalAudioPlayer(player, for: messageID)
        } else {
            startTimedProgressFallback(for: messageID, duration: currentDuration)
        }
    }

    func seek(messageID: String, to normalizedProgress: Double, fallbackDuration: Double) {
        let clamped = min(1.0, max(0.0, normalizedProgress))
        progressByMessage[messageID] = clamped
        guard activeMessageID == messageID else { return }

        if let player = audioPlayer, player.duration > 0 {
            player.currentTime = clamped * player.duration
        } else if let player = streamPlayer {
            let total = currentDuration > 0 ? currentDuration : max(1.0, fallbackDuration)
            let target = CMTime(seconds: clamped * total, preferredTimescale: 600)
            player.seek(to: target)
        }
    }

    func pause() {
        audioPlayer?.pause()
        streamPlayer?.pause()
        isPlaying = false
        progressTask?.cancel()
        progressTask = nil
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamPlayer = nil
        if let id = activeMessageID, (progressByMessage[id] ?? 0) >= 0.99 {
            progressByMessage[id] = 0
        }
        isPlaying = false
        activeMessageID = nil
    }

    // MARK: - Private Transport Helpers

    private func configurePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? session.setActive(true, options: [])
    }

    private func startLocalAudioPlayer(_ player: AVAudioPlayer, for messageID: String) {
        audioPlayer = player
        currentDuration = max(0.5, player.duration)
        if let existing = progressByMessage[messageID], existing > 0 && existing < 0.98 {
            player.currentTime = existing * player.duration
        } else {
            progressByMessage[messageID] = 0
        }
        player.prepareToPlay()
        player.play()
        isPlaying = true

        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(45))
                guard let self, self.activeMessageID == messageID else { return }
                guard let active = self.audioPlayer else { return }
                if active.isPlaying {
                    let ratio = active.duration > 0 ? active.currentTime / active.duration : 0
                    self.progressByMessage[messageID] = min(1.0, max(0.0, ratio))
                } else {
                    self.progressByMessage[messageID] = 0
                    self.isPlaying = false
                    self.activeMessageID = nil
                    return
                }
            }
        }
    }

    private func startRemoteStreamPlayer(url: URL, for messageID: String, fallbackDuration: Double) {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        streamPlayer = player
        if let existing = progressByMessage[messageID], existing > 0 && existing < 0.98 {
            player.seek(to: CMTime(seconds: existing * fallbackDuration, preferredTimescale: 600))
        } else {
            progressByMessage[messageID] = 0
        }
        player.play()
        isPlaying = true

        progressTask = Task { [weak self] in
            let startDate = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.activeMessageID == messageID, let active = self.streamPlayer else { return }
                let itemSeconds = active.currentItem?.duration.seconds ?? .nan
                let total = (itemSeconds.isFinite && itemSeconds > 0.2) ? itemSeconds : fallbackDuration
                self.currentDuration = total
                let currentSec = active.currentTime().seconds
                let effectiveElapsed = (currentSec.isFinite && currentSec > 0)
                    ? currentSec
                    : Date().timeIntervalSince(startDate)
                let ratio = min(1.0, max(0.0, effectiveElapsed / max(0.5, total)))
                self.progressByMessage[messageID] = ratio
                if ratio >= 1.0 {
                    self.progressByMessage[messageID] = 0
                    self.stop()
                    return
                }
            }
        }
    }

    private func startTimedProgressFallback(for messageID: String, duration: Double) {
        isPlaying = true
        let initial = progressByMessage[messageID] ?? 0
        let startFraction = initial >= 0.98 ? 0 : initial
        progressByMessage[messageID] = startFraction

        progressTask = Task { [weak self] in
            let start = Date().addingTimeInterval(-startFraction * duration)
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.activeMessageID == messageID else { return }
                let ratio = Date().timeIntervalSince(start) / max(0.5, duration)
                if ratio >= 1.0 {
                    self.progressByMessage[messageID] = 0
                    self.isPlaying = false
                    self.activeMessageID = nil
                    return
                }
                self.progressByMessage[messageID] = max(0, ratio)
            }
        }
    }

    /// Generates deterministic waveform bar heights (`5...22pt`) matching `public/js/views/bubbles.js:176-183`.
    static func waveformHeights(messageID: String, durationSeconds: Double) -> [CGFloat] {
        let secs = max(1, Int(durationSeconds.rounded()))
        let count = min(28, max(14, 12 + Int((Double(secs) * 0.8).rounded())))
        var seed: UInt32 = 0
        for scalar in messageID.unicodeScalars {
            seed = seed &* 31 &+ scalar.value
        }
        var bars: [CGFloat] = []
        bars.reserveCapacity(count)
        for index in 0..<count {
            seed = seed &* 1_103_515_245 &+ 12_345
            let envelope = sin(Double.pi * Double(index + 1) / Double(count + 1))
            let jitter = 0.45 + Double((seed >> 16) % 100) / 180.0
            let height = round(5.0 + envelope * 16.0 * jitter)
            bars.append(CGFloat(max(4.0, min(23.0, height))))
        }
        return bars
    }

    private static func makePlayableVoicePreviewWAV(durationSeconds: Double) -> Data {
        let sampleRate = 16_000
        let clampedSeconds = min(15.0, max(1.0, durationSeconds))
        let totalSamples = Int(clampedSeconds * Double(sampleRate))
        var samples = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let t = Double(i) / Double(sampleRate)
            let syllabicEnvelope = 0.35 + 0.65 * abs(sin(t * 4.2)) * abs(cos(t * 1.7))
            let fade = min(1.0, min(t / 0.06, (clampedSeconds - t) / 0.08))
            let wave = 0.55 * sin(2.0 * .pi * 220.0 * t) + 0.30 * sin(2.0 * .pi * 330.0 * t)
            samples[i] = Float(wave * syllabicEnvelope * max(0, fade) * 0.14)
        }
        return WAV16kMonoEncoder.encode(monoSamples: samples, sampleRate: sampleRate)
    }
}
