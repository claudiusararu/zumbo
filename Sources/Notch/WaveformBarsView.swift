import SwiftUI

/// Live level meter for the recording state.
///
/// Structure follows OpenDictation's WaveformView (MIT, see NOTICES.md): a
/// `TimelineView(.animation)` driving a travelling sine whose amplitude is the
/// smoothed microphone level. Bar count, geometry and the level mapping are
/// ours. Silence is flat, on purpose.
struct WaveformBarsView: View {

    /// Smoothed 0..1 level.
    var level: Float

    private let barCount = 15
    private let barWidth: CGFloat = 2
    private let spacing: CGFloat = 3
    private let waveSpeed: Double = 5.2
    private let phaseSpread: Double = 0.62
    /// The engine's level is RMS * 4, smoothed, and real speech only ever
    /// fills a sliver of 0...1: measured through `AudioCapture`'s own formula
    /// on the human recordings, a quiet room stays under 0.02 and speech runs
    /// 0.04...0.12. Treating the stream as if it used the whole 0...1 range is
    /// what kept the bars pinned at their baseline. So the meter maps that
    /// measured window onto the bar height instead.
    private let noiseFloor: Float = 0.02
    /// Where a bar reaches the top. Set at the p90 of measured speech, not the
    /// peak, so a normal voice uses most of the height instead of a sliver.
    private let fullScale: Float = 0.08
    /// Smallest bar, in points: a flat line, never nothing. Raised to the bar
    /// width so fully rounded (capsule) ends never look squashed.
    private let minBarHeight: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                HStack(spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                            .fill(Color.white.opacity(isQuiet ? 0.32 : 0.92))
                            .frame(width: barWidth, height: height(index, time: time, full: geo.size.height))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
        }
        .drawingGroup()
    }

    /// 0...1 after the noise gate and a mild curve, so a normal speaking
    /// voice reaches most of the height and a shout reaches all of it.
    private var amplitude: Double {
        guard level > noiseFloor else { return 0 }
        let span = Double((level - noiseFloor) / (fullScale - noiseFloor))
        return min(1, pow(min(1, span), 0.6))
    }

    private var isQuiet: Bool { amplitude <= 0.01 }

    private func height(_ index: Int, time: Double, full: CGFloat) -> CGFloat {
        // Flat faint line while nothing is being said.
        guard !isQuiet else { return minBarHeight }

        let phase = time * waveSpeed + Double(index) * phaseSpread
        let wave = (sin(phase) + 1) / 2

        // Taper the ends so the meter reads as a shape, not a picket fence.
        let position = Double(index) / Double(max(barCount - 1, 1))
        let taper = 0.6 + 0.4 * sin(position * .pi)

        // The travelling sine never takes a bar all the way down, so the row
        // keeps its shape while the whole envelope follows the voice.
        let scale = (0.45 + 0.55 * wave) * taper * amplitude
        return min(full, max(minBarHeight, full * CGFloat(scale)))
    }
}

#Preview("Waveform") {
    VStack(spacing: 12) {
        WaveformBarsView(level: 0.01).frame(width: 80, height: 18)   // quiet room
        WaveformBarsView(level: 0.05).frame(width: 80, height: 18)   // normal speech
        WaveformBarsView(level: 0.09).frame(width: 80, height: 18)   // loud
    }
    .padding(20)
    .background(.black)
}
