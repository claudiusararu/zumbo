import AVFoundation
import VesperEngine

/// Three short tones, synthesized in memory (no audio files): `start`, two
/// rising notes (C5 then E5); `finish`, the same two notes falling (E5 then
/// C5); `reminder`, a slower, higher pair (G5 then C6) in the same family so
/// it reads as one sound language, not a different alert. Built once as
/// `AVAudioPCMBuffer`s and played through a single `AVAudioEngine` +
/// `AVAudioPlayerNode`, started lazily on first play and restarted whenever
/// an output change (AirPods connecting, headphones unplugged) stopped it.
/// Routes through the default output only - this never touches
/// `engine.inputNode`, so it cannot interfere with the separate engine the
/// app uses to record the microphone at the same time.
@MainActor
final class Sounds {

    enum Tone {
        case start
        case finish
        case reminder
    }

    private static let sampleRate: Double = 44_100
    private static let noteHz: (low: Double, high: Double) = (523.0, 659.0) // C5, E5
    private static let noteDuration: Double = 0.070
    private static let attack: Double = 0.008
    private static let release: Double = 0.040
    private static let peak: Float = 0.18

    // The reminder tone: G5 then C6, slightly longer notes and a softer,
    // slower release than start/finish so it reads as a notice, not a click.
    private static let reminderHz: (low: Double, high: Double) = (784.0, 1047.0) // G5, C6
    private static let reminderNoteDuration: Double = 0.090
    private static let reminderAttack: Double = 0.008
    private static let reminderRelease: Double = 0.060
    private static let reminderPeak: Float = 0.16

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    private let startBuffer: AVAudioPCMBuffer
    private let finishBuffer: AVAudioPCMBuffer
    private let reminderBuffer: AVAudioPCMBuffer

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        startBuffer = Self.buildBuffer(notes: [Self.noteHz.low, Self.noteHz.high], format: format)
        finishBuffer = Self.buildBuffer(notes: [Self.noteHz.high, Self.noteHz.low], format: format)
        reminderBuffer = Self.buildBuffer(
            notes: [Self.reminderHz.low, Self.reminderHz.high], format: format,
            noteDuration: Self.reminderNoteDuration, attack: Self.reminderAttack,
            release: Self.reminderRelease, peak: Self.reminderPeak)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// Fire-and-forget: starts the engine when it is not running (first use,
    /// or after a device change stopped it), schedules the tone and returns
    /// immediately. Never blocks on I/O - `AVAudioEngine.start()` only
    /// configures the existing output graph, it does not open a device.
    /// Checks `isRunning`, not a started-once flag: a device change can stop
    /// the engine, and a flag would never start it again. A tone that cannot
    /// play is skipped; the engine and player calls go through the catcher
    /// because AVFAudio reports some device states by raising.
    func play(_ tone: Tone) {
        if !engine.isRunning {
            var started = false
            try? catchingObjCException { started = (try? engine.start()) != nil }
            guard started else { return }
        }
        let buffer: AVAudioPCMBuffer
        switch tone {
        case .start: buffer = startBuffer
        case .finish: buffer = finishBuffer
        case .reminder: buffer = reminderBuffer
        }
        try? catchingObjCException {
            player.scheduleBuffer(buffer, at: nil)
            if !player.isPlaying { player.play() }
        }
    }

    /// Sine notes back to back, each with an attack/sustain/release envelope
    /// so they click neither in nor out.
    private static func buildBuffer(
        notes: [Double], format: AVAudioFormat,
        noteDuration: Double = Sounds.noteDuration, attack: Double = Sounds.attack,
        release: Double = Sounds.release, peak: Float = Sounds.peak
    ) -> AVAudioPCMBuffer {
        let noteFrames = Int(noteDuration * sampleRate)
        let totalFrames = AVAudioFrameCount(noteFrames * notes.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        let samples = buffer.floatChannelData![0]

        var frame = 0
        for freq in notes {
            for i in 0..<noteFrames {
                let t = Double(i) / sampleRate
                var envelope: Double = 1
                if t < attack {
                    envelope = t / attack
                } else if t > noteDuration - release {
                    envelope = max(0, (noteDuration - t) / release)
                }
                let sample = sin(2 * Double.pi * freq * t) * Double(peak) * envelope
                samples[frame] = Float(sample)
                frame += 1
            }
        }
        return buffer
    }
}
