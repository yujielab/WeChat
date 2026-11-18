import Foundation
#if canImport(AVFAudio)
import AVFAudio
#endif

// MARK: - Apple HIG & Cuven Web Grounding
// - Apple Developer Documentation: AVAudioEngine / AVAudioPlayerNode / AVAudioPCMBuffer
// - Apple HIG: Playing Audio & Haptics (non-intrusive call progress feedback, zero audio clicks)
// - Cuven Web Reference: public/js/ui/tones.js (1-132)
//   * Ringback: 450 Hz sine wave, 1.0s pulse every 5.0s, soft linear attack (25ms) & release (50ms)
//   * Incoming Ringtone: 659.25 -> 783.99 -> 987.77 Hz (E5 -> G5 -> B5) struck bell pluck w/ 2x octave overtone,
//     two rounds (0.0s & 0.62s) every 3.0s
//   * Connect Triad: 659.25 -> 783.99 -> 987.77 Hz rising connect triad
//   * End Tone: 659.25 -> 440.0 Hz (E5 -> A4) falling two-note bell pluck

/// Pure mathematical PCM waveform synthesizer matching `public/js/ui/tones.js` sample-for-sample.
public enum CallToneSynthesizer {
    public static let defaultSampleRate: Double = 44_100.0

    public static let ringbackFrequencyHz: Double = 450.0
    public static let triadNoteE5Hz: Double = 659.25
    public static let triadNoteG5Hz: Double = 783.99
    public static let triadNoteB5Hz: Double = 987.77
    public static let endNoteA4Hz: Double = 440.00

    /// Synthesizes a 5.0-second loopable outgoing ringback buffer (`450 Hz` for `1.0s`, `4.0s` silence, `tones.js:41-54, 105-107`).
    public static func synthesizeRingbackCycle(sampleRate: Double = defaultSampleRate) -> [Float] {
        let totalDuration = 5.0
        let pulseDuration = 1.0
        let gain = 0.12
        let sampleCount = max(1, Int(totalDuration * sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)

        addSoftSineBeep(
            into: &samples,
            sampleRate: sampleRate,
            frequency: ringbackFrequencyHz,
            startTime: 0.0,
            duration: pulseDuration,
            peakGain: gain
        )
        return samples
    }

    /// Synthesizes a 3.0-second loopable incoming ringtone buffer (`659.25 -> 783.99 -> 987.77 Hz`, 2 rounds, `tones.js:110-117`).
    public static func synthesizeIncomingRingtoneCycle(sampleRate: Double = defaultSampleRate) -> [Float] {
        let totalDuration = 3.0
        let sampleCount = max(1, Int(totalDuration * sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)
        let notes = [triadNoteE5Hz, triadNoteG5Hz, triadNoteB5Hz]

        for round in 0..<2 {
            for (index, freq) in notes.enumerated() {
                let startAt = Double(round) * 0.62 + Double(index) * 0.13
                addBellPluck(
                    into: &samples,
                    sampleRate: sampleRate,
                    frequency: freq,
                    startTime: startAt,
                    peakGain: 0.16
                )
            }
        }
        return clampBuffer(samples)
    }

    /// Synthesizes the single rising connect triad (`659.25 -> 783.99 -> 987.77 Hz`) played once when a call connects.
    public static func synthesizeConnectTriad(sampleRate: Double = defaultSampleRate) -> [Float] {
        let totalDuration = 1.25
        let sampleCount = max(1, Int(totalDuration * sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)
        let notes = [triadNoteE5Hz, triadNoteG5Hz, triadNoteB5Hz]

        for (index, freq) in notes.enumerated() {
            addBellPluck(
                into: &samples,
                sampleRate: sampleRate,
                frequency: freq,
                startTime: 0.02 + Double(index) * 0.11,
                peakGain: 0.14
            )
        }
        return clampBuffer(samples)
    }

    /// Synthesizes the two-note falling call-end chime (`659.25 -> 440.0 Hz`, `tones.js:120-131`).
    public static func synthesizeEndTone(sampleRate: Double = defaultSampleRate) -> [Float] {
        let totalDuration = 1.20
        let sampleCount = max(1, Int(totalDuration * sampleRate))
        var samples = [Float](repeating: 0, count: sampleCount)

        addBellPluck(
            into: &samples,
            sampleRate: sampleRate,
            frequency: triadNoteE5Hz,
            startTime: 0.03,
            peakGain: 0.12
        )
        addBellPluck(
            into: &samples,
            sampleRate: sampleRate,
            frequency: endNoteA4Hz,
            startTime: 0.19,
            peakGain: 0.12
        )
        return clampBuffer(samples)
    }

    // MARK: - Envelope Primitives (`beep` & `pluck` from `tones.js:41-71`)

    private static func addSoftSineBeep(
        into buffer: inout [Float],
        sampleRate: Double,
        frequency: Double,
        startTime: Double,
        duration: Double,
        peakGain: Double
    ) {
        let startIndex = max(0, Int(startTime * sampleRate))
        let endIndex = min(buffer.count, Int((startTime + duration) * sampleRate))
        guard endIndex > startIndex else { return }

        let attack = 0.025
        let release = 0.050
        let twoPiF = 2.0 * Double.pi * frequency

        for idx in startIndex..<endIndex {
            let localT = Double(idx - startIndex) / sampleRate
            let envelope: Double
            if localT < attack {
                envelope = peakGain * (localT / attack)
            } else if localT > duration - release {
                let remaining = max(0, duration - localT)
                envelope = peakGain * (remaining / release)
            } else {
                envelope = peakGain
            }
            let sample = sin(twoPiF * localT) * envelope
            buffer[idx] += Float(sample)
        }
    }

    /// Struck bell note with exponential attack (`12ms`) & exponential decay (`900ms`) + `2x` octave harmonic (`0.18` share).
    private static func addBellPluck(
        into buffer: inout [Float],
        sampleRate: Double,
        frequency: Double,
        startTime: Double,
        peakGain: Double
    ) {
        let noteDuration = 0.90
        let startIndex = max(0, Int(startTime * sampleRate))
        let endIndex = min(buffer.count, Int((startTime + noteDuration) * sampleRate))
        guard endIndex > startIndex else { return }

        let attack = 0.012
        let floorGain = 0.0001
        let partials: [(multiplier: Double, share: Double)] = [(1.0, 1.0), (2.0, 0.18)]

        for (multiplier, share) in partials {
            let targetPeak = max(floorGain * 1.01, peakGain * share)
            let attackRatio = targetPeak / floorGain
            let decayRatio = floorGain / targetPeak
            let twoPiF = 2.0 * Double.pi * (frequency * multiplier)

            for idx in startIndex..<endIndex {
                let localT = Double(idx - startIndex) / sampleRate
                let env: Double
                if localT <= attack {
                    let progress = localT / attack
                    env = floorGain * pow(attackRatio, progress)
                } else {
                    let progress = min(1.0, (localT - attack) / (noteDuration - attack))
                    env = targetPeak * pow(decayRatio, progress)
                }
                // Smooth final 10ms tail to strict zero so loops/stops never click.
                let tailFade = localT > (noteDuration - 0.010)
                    ? max(0.0, (noteDuration - localT) / 0.010)
                    : 1.0
                let sample = sin(twoPiF * localT) * env * tailFade
                buffer[idx] += Float(sample)
            }
        }
    }

    private static func clampBuffer(_ samples: [Float]) -> [Float] {
        samples.map { min(0.98, max(-0.98, $0)) }
    }
}

/// Native `AVAudioEngine` call tone player matching Web `tones.js`.
/// Gracefully handles Simulator / headless environments without audio hardware — never throws.
@MainActor
public final class CallSynthesizedTones {
    public static let shared = CallSynthesizedTones()

    public enum ActiveLoopKind: Equatable, Sendable {
        case none
        case outgoingRingback
        case incomingRingtone
    }

    public private(set) var activeLoop: ActiveLoopKind = .none

    #if canImport(AVFAudio)
    private var engine: AVAudioEngine?
    private var loopPlayer: AVAudioPlayerNode?
    private var oneShotPlayer: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var teardownTask: Task<Void, Never>?
    #endif

    public init() {}

    /// Primes audio engine on user tap so ringback/chimes start with zero latency (`primeTones()`).
    public func prime() {
        #if canImport(AVFAudio)
        teardownTask?.cancel()
        _ = ensureEngineRunning()
        #endif
    }

    /// Plays looping `450 Hz` outgoing ringback (`1.0s` pulse every `5.0s`).
    public func startRingback() {
        guard activeLoop != .outgoingRingback else { return }
        stopLoopingTones()
        activeLoop = .outgoingRingback
        #if canImport(AVFAudio)
        scheduleSamples(
            CallToneSynthesizer.synthesizeRingbackCycle(),
            loops: true
        )
        #endif
    }

    /// Plays looping rising bell triad (`659.25 -> 783.99 -> 987.77 Hz`) for incoming calls.
    public func startIncomingRingtone() {
        guard activeLoop != .incomingRingtone else { return }
        stopLoopingTones()
        activeLoop = .incomingRingtone
        #if canImport(AVFAudio)
        scheduleSamples(
            CallToneSynthesizer.synthesizeIncomingRingtoneCycle(),
            loops: true
        )
        #endif
    }

    /// Stops any active ringback or incoming ringtone loop immediately.
    public func stopLoopingTones() {
        activeLoop = .none
        #if canImport(AVFAudio)
        loopPlayer?.stop()
        #endif
    }

    /// Plays the rising connect triad (`659.25 -> 783.99 -> 987.77 Hz`) once upon call connection.
    public func playConnectTriad() {
        stopLoopingTones()
        #if canImport(AVFAudio)
        teardownTask?.cancel()
        scheduleSamples(
            CallToneSynthesizer.synthesizeConnectTriad(),
            loops: false
        )
        #endif
    }

    /// Plays the falling call-end chime (`659.25 -> 440.0 Hz`) and schedules audio hardware release (`1.5s`).
    public func playEndTone() {
        stopLoopingTones()
        #if canImport(AVFAudio)
        teardownTask?.cancel()
        scheduleSamples(
            CallToneSynthesizer.synthesizeEndTone(),
            loops: false
        )
        scheduleEngineRelease(afterSeconds: 1.5)
        #endif
    }

    /// Releases the underlying `AVAudioEngine` cleanly (`releaseTones()`).
    public func releaseSoon() {
        stopLoopingTones()
        #if canImport(AVFAudio)
        scheduleEngineRelease(afterSeconds: 1.5)
        #endif
    }

    #if canImport(AVFAudio)
    private func ensureEngineRunning() -> Bool {
        if let existing = engine, existing.isRunning {
            return true
        }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: CallToneSynthesizer.defaultSampleRate,
            channels: 1,
            interleaved: false
        )
        guard let format else { return false }

        if engine == nil {
            let newEngine = AVAudioEngine()
            let outputHardwareFormat = newEngine.outputNode.outputFormat(forBus: 0)
            // Guard against 0-channel / 0-Hz CoreAudio output on headless CI runners (prevents ObjC NSException)
            guard outputHardwareFormat.channelCount > 0, outputHardwareFormat.sampleRate > 0 else {
                return false
            }
            let loopNode = AVAudioPlayerNode()
            let shotNode = AVAudioPlayerNode()
            newEngine.attach(loopNode)
            newEngine.attach(shotNode)
            newEngine.connect(loopNode, to: newEngine.mainMixerNode, format: format)
            newEngine.connect(shotNode, to: newEngine.mainMixerNode, format: format)
            self.engine = newEngine
            self.loopPlayer = loopNode
            self.oneShotPlayer = shotNode
            self.audioFormat = format
        }

        do {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playAndRecord {
                try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            }
            if let engine, !engine.isRunning {
                try engine.start()
            }
            return engine?.isRunning == true
        } catch {
            // Headless CI Simulator without audio output unit: fail silently per tones.js contract.
            return false
        }
    }

    private func scheduleSamples(_ samples: [Float], loops: Bool) {
        teardownTask?.cancel()
        guard ensureEngineRunning(),
              let format = audioFormat,
              let pcmBuffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channelData = pcmBuffer.floatChannelData?[0]
        else {
            return
        }

        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            channelData.update(from: base, count: samples.count)
        }

        let targetNode = loops ? loopPlayer : oneShotPlayer
        guard let targetNode else { return }
        targetNode.stop()
        targetNode.scheduleBuffer(pcmBuffer, at: nil, options: loops ? [.loops] : [], completionHandler: nil)
        if engine?.isRunning == true {
            targetNode.play()
        }
    }

    private func scheduleEngineRelease(afterSeconds delay: Double) {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.activeLoop == .none else { return }
            self.loopPlayer?.stop()
            self.oneShotPlayer?.stop()
            self.engine?.stop()
        }
    }
    #endif
}
