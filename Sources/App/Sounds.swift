import AVFoundation
import CoreAudio
import VesperEngine

/// Three short tones, synthesized in memory (no audio files): `start`, two
/// rising notes (C5 then E5); `finish`, the same two notes falling (E5 then
/// C5); `reminder`, a slower, higher pair (G5 then C6) in the same family so
/// it reads as one sound language, not a different alert. Built once as
/// `AVAudioPCMBuffer`s and played through one `AVAudioEngine` +
/// `AVAudioPlayerNode`, built lazily on first play and built again whenever
/// the default output changes (AirPods connecting, headphones unplugged).
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

    /// Rebuilt whenever the default output device is not the one it was built
    /// on. An engine built for the laptop speakers keeps playing after AirPods
    /// connect, but the start tone comes out broken in the AirPods; a fresh
    /// engine sounds right, same as launching the app with them connected.
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var engineOutputDevice: AudioDeviceID?
    private let format: AVAudioFormat

    private let startBuffer: AVAudioPCMBuffer
    private let finishBuffer: AVAudioPCMBuffer
    private let reminderBuffer: AVAudioPCMBuffer

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        startBuffer = Self.buildBuffer(notes: [Self.noteHz.low, Self.noteHz.high], format: format)
        finishBuffer = Self.buildBuffer(notes: [Self.noteHz.high, Self.noteHz.low], format: format)
        reminderBuffer = Self.buildBuffer(
            notes: [Self.reminderHz.low, Self.reminderHz.high], format: format,
            noteDuration: Self.reminderNoteDuration, attack: Self.reminderAttack,
            release: Self.reminderRelease, peak: Self.reminderPeak)
    }

    /// Fire-and-forget: makes sure the engine is running on the current
    /// output device (building a fresh one on first use or after the output
    /// changed), schedules the tone and returns immediately. Never blocks on
    /// I/O - `AVAudioEngine.start()` only configures the output graph, it
    /// does not open a device. A tone that cannot play is skipped; the
    /// engine and player calls go through the catcher because AVFAudio
    /// reports some device states by raising.
    func play(_ tone: Tone) {
        let output = Self.defaultOutputDevice()
        if output != engineOutputDevice || !engine.isRunning {
            guard rebuildEngine(for: output) else { return }
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

    /// Replaces the engine and player with fresh ones wired for `output` and
    /// starts them. Returns false when the engine will not start; the next
    /// `play` tries again.
    private func rebuildEngine(for output: AudioDeviceID?) -> Bool {
        engine.stop()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        var started = false
        try? catchingObjCException { started = (try? engine.start()) != nil }
        engineOutputDevice = started ? output : nil
        return started
    }

    /// True when the default output is a Bluetooth device (AirPods and other
    /// headsets), the one kind of output that changes mode when the
    /// microphone opens.
    var outputIsBluetooth: Bool {
        guard let device = Self.defaultOutputDevice() else { return false }
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// The system's default output device right now, or nil if CoreAudio
    /// cannot say. One property read, cheap enough to do on every tone.
    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
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
