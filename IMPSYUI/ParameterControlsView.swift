import SwiftUI

struct ParameterControlsView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(spacing: 8) {
            ParameterRow(label: "Threshold",
                         value: $viewModel.threshold,
                         range: ParameterRanges.thresholdMin...ParameterRanges.thresholdMax,
                         format: "%.1f s",
                         identifier: "param.threshold")
            ParameterRow(label: "Sigma Temp",
                         value: $viewModel.sigmaTemp,
                         range: ParameterRanges.sigmaTempMin...ParameterRanges.sigmaTempMax,
                         format: "%.3f",
                         identifier: "param.sigmaTemp")
            ParameterRow(label: "Pi Temp",
                         value: $viewModel.piTemp,
                         range: ParameterRanges.piTempMin...ParameterRanges.piTempMax,
                         format: "%.2f",
                         identifier: "param.piTemp")
            ParameterRow(label: "Timescale",
                         value: $viewModel.timescale,
                         range: ParameterRanges.timescaleMin...ParameterRanges.timescaleMax,
                         format: "%.2f ×",
                         identifier: "param.timescale")
            HStack(spacing: 8) {
                Text("MIDI Thru")
                    .frame(width: 80, alignment: .leading)
                    .font(.system(.caption, design: .rounded))
                Toggle("", isOn: $viewModel.inputThru)
                    .labelsHidden()
                    .accessibilityIdentifier("param.inputThru")
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Dedup Controls

/// Two sliders that govern output dedup: same-value MIDI emissions inside the
/// chosen window are dropped. The CC slider also covers pitch bend.
struct DedupControlsView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(spacing: 8) {
            ParameterRow(label: "Note Window",
                         value: $viewModel.dedupNoteWindowMs,
                         range: ParameterRanges.dedupWindowMin...ParameterRanges.dedupWindowMax,
                         format: "%.0f ms",
                         identifier: "param.dedupNoteWindowMs")
            ParameterRow(label: "CC Window",
                         value: $viewModel.dedupCCWindowMs,
                         range: ParameterRanges.dedupWindowMin...ParameterRanges.dedupWindowMax,
                         format: "%.0f ms",
                         identifier: "param.dedupCCWindowMs")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Individual Parameter Row

private struct ParameterRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let format: String
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .font(.system(.caption, design: .rounded))
            SlimParameterBar(value: $value,
                             range: range,
                             label: label,
                             formattedValue: String(format: format, value),
                             tint: .accentColor)
            Text(String(format: format, value))
                .frame(width: 60, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .accessibilityIdentifier("\(identifier).value")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Slim Interactive Bar
//
// Replaces a stock `Slider` with a low-profile horizontal bar: a filled
// capsule shows the current value and a thin tick marks the position.
// Drag (or tap) anywhere along the bar sets the value, so the control is
// still usable when a MIDI controller isn't driving it.
//
// Reused by the Dashboard's per-dimension faders, hence `internal` and the
// caller-provided `tint`.

struct SlimParameterBar: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let label: String
    let formattedValue: String
    var tint: Color = .accentColor
    /// When `false`, the tick marker only appears while the user is dragging.
    /// Used by the Dashboard's per-dimension faders so a long stack of bars
    /// reads as a clean progress meter at rest.
    var showsTickWhenIdle: Bool = true

    @State private var isInteracting: Bool = false

    private static let barHeight: CGFloat = 6
    private static let tickHeight: CGFloat = 14
    private static let hitHeight: CGFloat = 22

    private var normalized: CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return CGFloat((clamped - range.lowerBound) / span)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fillWidth = max(0, min(width, width * normalized))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.10))
                    .frame(height: Self.barHeight)
                Capsule()
                    .fill(tint.opacity(0.65))
                    .frame(width: fillWidth, height: Self.barHeight)
                Rectangle()
                    .fill(Color.primary.opacity(0.85))
                    .frame(width: 2, height: Self.tickHeight)
                    .offset(x: max(0, fillWidth - 1))
                    .opacity(showsTickWhenIdle || isInteracting ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isInteracting)
            }
            .frame(width: width, height: Self.hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard width > 0 else { return }
                        isInteracting = true
                        let x = min(max(g.location.x, 0), width)
                        let frac = Float(x / width)
                        let span = range.upperBound - range.lowerBound
                        value = range.lowerBound + frac * span
                    }
                    .onEnded { _ in
                        isInteracting = false
                    }
            )
        }
        .frame(height: Self.hitHeight)
        .accessibilityElement()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(formattedValue))
        .accessibilityAdjustableAction { direction in
            let span = range.upperBound - range.lowerBound
            let step = span / 20
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default:
                break
            }
        }
    }
}
