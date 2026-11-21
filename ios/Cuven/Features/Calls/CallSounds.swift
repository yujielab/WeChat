import AVFoundation
import AudioToolbox
import UIKit

/// The sounds of a call, made here rather than read from system files (which
/// an app can't count on): the ring and its vibration while a call comes in,
/// the ringback while yours rings at the other end, and a short fall of tones
/// when it ends.
@MainActor
final class CallSounds {
    private var player: AVAudioPlayer?
    private var buzz: Timer?

    /// An incoming call: a soft two-note chime every two seconds, silenced by
    /// the Ring/Silent switch like any ringtone, and a vibration with it.
    func ring() {
        stop()
        let s = AVAudioSession.sharedInstance()
        // Solo ambient honours the silent switch; the vibration still comes.
        try? s.setCategory(.soloAmbient, mode: .default)
        try? s.setActive(true)
        play(Tone.ringtone, volume: 0.8)
        vibrate()
        buzz = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in CallSounds.vibrateOnce() }
        }
    }

    /// Your call ringing at the other end: the long-and-pause of a ringback,
    /// quietly, through the call's own route (the earpiece for a voice call).
    func ringback() {
        stop()
        play(Tone.ringback, volume: 0.32)
    }

    /// Three short falling tones as a call ends.
    func ended() {
        stop()
        play(Tone.ended, volume: 0.35, loops: 0)
    }

    func stop() {
        player?.stop()
        player = nil
        buzz?.invalidate()
        buzz = nil
    }

    private func play(_ data: Data, volume: Float, loops: Int = -1) {
        guard let p = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue) else { return }
        p.numberOfLoops = loops
        p.volume = volume
        p.prepareToPlay()
        p.play()
        player = p
    }

    private func vibrate() { Self.vibrateOnce() }

    private static func vibrateOnce() {
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
    }
}

/// Tones as 16-bit mono WAV, built once.
enum Tone {
    static let rate = 22_050

    /// 450 Hz, a second on and four off (the ringback heard in China).
    static let ringback: Data = wav(sequence([(450, 1.0, 0.9), (0, 4.0, 0)]))

    /// E6 then B5, soft-edged, then quiet to two seconds.
    static let ringtone: Data = wav(sequence([(1318.5, 0.16, 0.55), (0, 0.04, 0), (987.8, 0.26, 0.5), (0, 1.54, 0)], partial: 2))

    /// G5, E5, C5: short, falling.
    static let ended: Data = wav(sequence([(784, 0.12, 0.5), (0, 0.05, 0), (659.3, 0.12, 0.5), (0, 0.05, 0), (523.3, 0.2, 0.5)]))

    /// Steps of (frequency, seconds, level); a frequency of 0 is silence.
    /// `partial` adds a quiet octave above, for a bell-like edge.
    private static func sequence(_ steps: [(Double, Double, Double)], partial: Double = 0) -> [Int16] {
        var out: [Int16] = []
        for (f, secs, level) in steps {
            let n = Int(secs * Double(rate))
            let fade = min(n / 2, Int(0.012 * Double(rate)))
            out.reserveCapacity(out.count + n)
            for i in 0..<n {
                guard f > 0 else { out.append(0); continue }
                let t = Double(i) / Double(rate)
                var v = sin(2 * .pi * f * t)
                if partial > 0 { v = (v + 0.25 * sin(2 * .pi * f * partial * t)) / 1.25 }
                // Soft attack and release, so nothing clicks.
                var env = 1.0
                if i < fade { env = Double(i) / Double(fade) } else if i > n - fade { env = Double(n - i) / Double(fade) }
                // A gentle decay on the chime's notes.
                if partial > 0 { env *= exp(-3.2 * t / max(secs, 0.01)) * 1.4 }
                out.append(Int16(max(-1, min(1, v * env * level)) * 32_000))
            }
        }
        return out
    }

    private static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
