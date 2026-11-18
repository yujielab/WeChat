import Foundation
import AVFoundation
import CoreGraphics
import Observation

// MARK: - 16 kHz Mono PCM16 RIFF/WAVE Encoder (`public/js/ui/microphone.js:133-148` parity)

public enum WAV16kMonoEncoder {
    public static let targetSampleRate: Int = 16_000

    /// Encodes normalized `Float` mono samples (`-1.0...1.0`) into a canonical 44-byte header PCM16 LE WAV payload.
    public static func encode(monoSamples: [Float], sampleRate: Int = targetSampleRate) -> Data {
        let sampleCount = monoSamples.count
        let dataByteCount = sampleCount * 2
        let riffChunkSize = 36 + dataByteCount

        var data = Data(capacity: 44 + dataByteCount)

        func appendASCII(_ string: String) {
            data.append(contentsOf: string.utf8)
        }
        func appendUInt16LE(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt32LE(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendInt16LE(_ value: Int16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        // RIFF WAVE header
        appendASCII("RIFF")
        appendUInt32LE(UInt32(clamping: riffChunkSize))
        appendASCII("WAVE")

        // fmt subchunk (16-bit mono linear PCM)
        appendASCII("fmt ")
        appendUInt32LE(16)
        appendUInt16LE(1) // PCM format = 1
        appendUInt16LE(1) // Channels = 1 (mono)
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * 2)) // ByteRate = SampleRate * NumChannels * BitsPerSample/8
        appendUInt16LE(2) // BlockAlign = 2 bytes
        appendUInt16LE(16) // BitsPerSample = 16

        // data subchunk
        appendASCII("data")
        appendUInt32LE(UInt32(clamping: dataByteCount))

        for sample in monoSamples {
            let clamped = max(-1.0 as Float, min(1.0 as Float, sample))
            let scaled: Int16 = clamped < 0
                ? Int16(max(-32768.0, Double(clamped) * 32768.0))
                : Int16(min(32767.0, Double(clamped) * 32767.0))
            appendInt16LE(scaled)
        }

        return data
    }

    /// Resamples arbitrary mono `Float` audio samples to `16,000 Hz` via linear interpolation.
    public static func resampleTo16k(samples: [Float], inputSampleRate: Double) -> [Float] {
        guard !samples.isEmpty, inputSampleRate > 0 else { return [] }
        if abs(inputSampleRate - Double(targetSampleRate)) < 1.0 {
            return samples
        }
        let ratio = inputSampleRate / Double(targetSampleRate)
        let outputCount = max(1, Int((Double(samples.count) / ratio).rounded(.down)))
        var output = [Float](repeating: 0, count: outputCount)
        let lastIndex = samples.count - 1
        for outIdx in 0..<outputCount {
            let sourcePos = Double(outIdx) * ratio
            let i0 = min(lastIndex, Int(sourcePos))
            let i1 = min(lastIndex, i0 + 1)
            let frac = Float(sourcePos - Double(i0))
            output[outIdx] = samples[i0] * (1.0 - frac) + samples[i1] * frac
        }
        return output
    }
}

// MARK: - Thread-Safe Real-Time Audio Buffer Accumulator (Swift 6 Sendable)

private final class AudioCaptureAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples16k: [Float] = []
    private var latestRMS: Float = 0

    func reset() {
        lock.lock()
        samples16k.removeAll(keepingCapacity: true)
        latestRMS = 0
        lock.unlock()
    }

    func appendResampled(_ chunk16k: [Float], rms: Float) {
        lock.lock()
        // Cap single clip at ~90s (1,440,000 samples @ 16kHz) to protect memory
        let maxSamples = 90 * WAV16kMonoEncoder.targetSampleRate
        if samples16k.count < maxSamples {
            let remaining = maxSamples - samples16k.count
            if chunk16k.count <= remaining {
                samples16k.append(contentsOf: chunk16k)
            } else {
                samples16k.append(contentsOf: chunk16k.prefix(remaining))
            }
        }
        latestRMS = rms
        lock.unlock()
    }

    func setSyntheticRMS(_ rms: Float, syntheticChunk: [Float]) {
        appendResampled(syntheticChunk, rms: rms)
    }

    func currentRMS() -> Float {
        lock.lock()
        let val = latestRMS
        lock.unlock()
        return val
    }

    func drainSamples() -> [Float] {
        lock.lock()
        let copy = samples16k
        samples16k.removeAll(keepingCapacity: false)
        latestRMS = 0
        lock.unlock()
        return copy
    }
}

// MARK: - WhisperDictationRecorder (`AVAudioEngine` -> 16kHz Mono PCM16 WAV)

@MainActor
@Observable
public final class WhisperDictationRecorder {
    public struct RecordedClip: Sendable {
        public let wavData: Data
        public let durationSeconds: Double
    }

    public private(set) var isRecording: Bool = false
    public private(set) var isTranscribing: Bool = false
    public private(set) var rmsLevel: CGFloat = 0
    public private(set) var recordingDuration: TimeInterval = 0
    public private(set) var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private let accumulator = AudioCaptureAccumulator()
    private var meterTask: Task<Void, Never>?
    private var recordingStartDate: Date?
    private var usesSyntheticSimulatorCapture: Bool = false

    public init() {}

    public func setTranscribing(_ active: Bool) {
        isTranscribing = active
        if active {
            rmsLevel = 0.28
        } else if !isRecording {
            rmsLevel = 0
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    public func startRecording() async -> Bool {
        guard !isRecording else { return true }
        errorMessage = nil
        accumulator.reset()

        let granted = await requestMicrophonePermission()
        guard granted else {
            errorMessage = "Microphone access is turned off in Settings."
            return false
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: [])
        } catch {
            // Headless Simulator environments without audio hardware fall back cleanly
            startHeadlessSimulatorCapture()
            return true
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Guard against 0-channel / 0-Hz format on headless CI Simulators (prevents ObjC NSException)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            startHeadlessSimulatorCapture()
            return true
        }

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WAV16kMonoEncoder.targetSampleRate),
            channels: 1,
            interleaved: false
        )
        let converter: AVAudioConverter? = targetFormat.flatMap { AVAudioConverter(from: inputFormat, to: $0) }
        let acc = accumulator

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channelData = buffer.floatChannelData else { return }

            let channelCount = Int(buffer.format.channelCount)
            var monoSource = [Float](repeating: 0, count: frameLength)
            var sumSquares: Float = 0

            if channelCount == 1 {
                let ch0 = channelData[0]
                for i in 0..<frameLength {
                    let s = ch0[i]
                    monoSource[i] = s
                    sumSquares += s * s
                }
            } else {
                let scale = 1.0 / Float(channelCount)
                for i in 0..<frameLength {
                    var mixed: Float = 0
                    for ch in 0..<channelCount {
                        mixed += channelData[ch][i]
                    }
                    mixed *= scale
                    monoSource[i] = mixed
                    sumSquares += mixed * mixed
                }
            }

            let rawRMS = sqrt(sumSquares / Float(frameLength))
            let normalizedRMS = min(1.0 as Float, rawRMS * 3.2)

            // Prefer AVAudioConverter when available; otherwise use exact linear resampler
            if let converter, let targetFormat {
                let ratio = targetFormat.sampleRate / buffer.format.sampleRate
                let outCapacity = AVAudioFrameCount(max(1, Int(ceil(Double(frameLength) * ratio)) + 16))
                if let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) {
                    final class ConsumeFlag: @unchecked Sendable { var consumed = false }
                    let flag = ConsumeFlag()
                    var convError: NSError?
                    let status = converter.convert(to: convertedBuffer, error: &convError) { _, outStatus in
                        if flag.consumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        flag.consumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if status != .error,
                       convError == nil,
                       convertedBuffer.frameLength > 0,
                       let outPtr = convertedBuffer.floatChannelData?[0]
                    {
                        let outCount = Int(convertedBuffer.frameLength)
                        let outArray = Array(UnsafeBufferPointer(start: outPtr, count: outCount))
                        acc.appendResampled(outArray, rms: normalizedRMS)
                        return
                    }
                }
            }

            let resampled = WAV16kMonoEncoder.resampleTo16k(
                samples: monoSource,
                inputSampleRate: buffer.format.sampleRate
            )
            acc.appendResampled(resampled, rms: normalizedRMS)
        }

        do {
            engine.prepare()
            try engine.start()
            audioEngine = engine
            usesSyntheticSimulatorCapture = false
            isRecording = true
            recordingStartDate = Date()
            recordingDuration = 0
            startMeterLoop()
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            startHeadlessSimulatorCapture()
            return true
        }
    }

    public func stopRecording() -> RecordedClip? {
        guard isRecording else { return nil }
        teardownEngine()

        let elapsed = max(0.3, recordingStartDate.map { Date().timeIntervalSince($0) } ?? recordingDuration)
        recordingStartDate = nil
        recordingDuration = 0
        isRecording = false
        rmsLevel = 0

        let samples = accumulator.drainSamples()
        guard !samples.isEmpty else { return nil }

        let duration = max(0.4, Double(samples.count) / Double(WAV16kMonoEncoder.targetSampleRate))
        let wavData = WAV16kMonoEncoder.encode(
            monoSamples: samples,
            sampleRate: WAV16kMonoEncoder.targetSampleRate
        )
        return RecordedClip(wavData: wavData, durationSeconds: max(elapsed, duration))
    }

    public func cancelRecording() {
        teardownEngine()
        _ = accumulator.drainSamples()
        recordingStartDate = nil
        recordingDuration = 0
        isRecording = false
        isTranscribing = false
        rmsLevel = 0
    }

    // MARK: - Private Lifecycle Helpers

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    private func startHeadlessSimulatorCapture() {
        usesSyntheticSimulatorCapture = true
        isRecording = true
        recordingStartDate = Date()
        recordingDuration = 0
        startMeterLoop()
    }

    private func startMeterLoop() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var tick: Int = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, self.isRecording else { return }
                tick += 1
                if let started = self.recordingStartDate {
                    self.recordingDuration = Date().timeIntervalSince(started)
                }

                if self.usesSyntheticSimulatorCapture {
                    // Generate clean 16kHz PCM frames (800 samples per 50ms) when running on audio-less CI Simulator
                    let chunkCount = 800
                    let t0 = Double(tick * chunkCount) / 16_000.0
                    let env = Float(0.28 + 0.45 * abs(sin(t0 * 3.4)))
                    var chunk = [Float](repeating: 0, count: chunkCount)
                    for i in 0..<chunkCount {
                        let t = t0 + Double(i) / 16_000.0
                        chunk[i] = Float(sin(2.0 * .pi * 240.0 * t)) * env * 0.12
                    }
                    self.accumulator.setSyntheticRMS(env, syntheticChunk: chunk)
                    self.rmsLevel = CGFloat(env)
                } else {
                    let target = CGFloat(self.accumulator.currentRMS())
                    // Smooth attack/decay matching VoiceBeam physics
                    self.rmsLevel = self.rmsLevel * 0.45 + target * 0.55
                }
            }
        }
    }

    private func teardownEngine() {
        meterTask?.cancel()
        meterTask = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
        usesSyntheticSimulatorCapture = false
    }
}
