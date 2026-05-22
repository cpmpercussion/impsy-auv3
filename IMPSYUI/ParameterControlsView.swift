import SwiftUI

struct ParameterControlsView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(spacing: 8) {
            ParameterRow(label: "Threshold",
                         value: $viewModel.threshold,
                         range: ParameterRanges.thresholdMin...ParameterRanges.thresholdMax,
                         format: "%.1f s")
            ParameterRow(label: "Sigma Temp",
                         value: $viewModel.sigmaTemp,
                         range: ParameterRanges.sigmaTempMin...ParameterRanges.sigmaTempMax,
                         format: "%.3f")
            ParameterRow(label: "Pi Temp",
                         value: $viewModel.piTemp,
                         range: ParameterRanges.piTempMin...ParameterRanges.piTempMax,
                         format: "%.2f")
            ParameterRow(label: "Timescale",
                         value: $viewModel.timescale,
                         range: ParameterRanges.timescaleMin...ParameterRanges.timescaleMax,
                         format: "%.2f ×")
            HStack(spacing: 8) {
                Text("MIDI Thru")
                    .frame(width: 80, alignment: .leading)
                    .font(.system(.caption, design: .rounded))
                Toggle("", isOn: $viewModel.inputThru)
                    .labelsHidden()
                Spacer()
            }
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

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 80, alignment: .leading)
                .font(.system(.caption, design: .rounded))
            Slider(value: $value, in: range)
            Text(String(format: format, value))
                .frame(width: 60, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
        }
    }
}
