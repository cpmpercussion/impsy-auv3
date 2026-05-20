import SwiftUI

// MARK: - Mapping Editor View

struct MappingEditorView: View {
    @ObservedObject var viewModel: IMPSYViewModel
    @State private var selectedTab: MappingTab = .input

    enum MappingTab: String, CaseIterable {
        case input  = "Input"
        case output = "Output"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mapping", selection: $selectedTab) {
                ForEach(MappingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            let isInput  = selectedTab == .input
            let mappings = isInput ? viewModel.mappings.inputMappings
                                   : viewModel.mappings.outputMappings

            if mappings.isEmpty {
                Text("No model loaded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                // No inner ScrollView: the parent view already scrolls, and
                // nesting vertical scroll views fights for the drag gesture.
                VStack(spacing: 6) {
                    ForEach(mappings.indices, id: \.self) { idx in
                        MappingRow(
                            dimensionIndex: idx + 1,
                            mapping: binding(at: idx, isInput: isInput)
                        )
                        if idx < mappings.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// Two-way binding into one entry of the active (input/output) mapping list.
    private func binding(at idx: Int, isInput: Bool) -> Binding<DimensionMapping> {
        Binding(
            get: {
                let arr = isInput ? viewModel.mappings.inputMappings
                                  : viewModel.mappings.outputMappings
                return arr.indices.contains(idx) ? arr[idx]
                                                 : .defaults(forDimension: idx + 1)
            },
            set: { newValue in
                if isInput {
                    guard viewModel.mappings.inputMappings.indices.contains(idx) else { return }
                    viewModel.mappings.inputMappings[idx] = newValue
                } else {
                    guard viewModel.mappings.outputMappings.indices.contains(idx) else { return }
                    viewModel.mappings.outputMappings[idx] = newValue
                }
                viewModel.saveMappings()
            }
        )
    }
}

// MARK: - Single Mapping Row

private struct MappingRow: View {
    let dimensionIndex: Int
    @Binding var mapping: DimensionMapping

    var body: some View {
        HStack(spacing: 8) {
            // Dimension badge
            Text("\(dimensionIndex)")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))

            // Message type — flexible width, truncates before the steppers do
            Picker("", selection: $mapping.messageType) {
                ForEach(MIDIMessageType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            // Channel (1–16) and note/CC number (0–127)
            CompactStepper(label: "Ch", value: $mapping.channel, range: 1...16)
            CompactStepper(label: numberLabel, value: $mapping.number,
                           range: 0...127, enabled: mapping.messageType.usesNumber)
        }
    }

    private var numberLabel: String {
        switch mapping.messageType {
        case .noteOn:        return "Note"
        case .controlChange: return "CC"
        case .pitchBend:     return "—"
        }
    }
}

// MARK: - Compact Stepper

/// A tightly-packed −/value/+ control. Native `Stepper` is too wide to fit
/// two per row alongside a type picker on a phone-width screen.
private struct CompactStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                stepButton("minus", active: enabled && value > range.lowerBound) {
                    value = max(range.lowerBound, value - 1)
                }
                Text(enabled ? "\(value)" : "–")
                    .font(.system(.caption, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 30)
                stepButton("plus", active: enabled && value < range.upperBound) {
                    value = min(range.upperBound, value + 1)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .opacity(enabled ? 1 : 0.4)
        }
        .fixedSize()
    }

    private func stepButton(_ systemName: String, active: Bool,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!active)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
    }
}
