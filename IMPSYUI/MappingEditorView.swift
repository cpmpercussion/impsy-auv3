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
                // Master "all on / all off" toggle. Tri-state: if any row is
                // disabled, ticking it re-enables everything; if all rows are
                // already on, ticking sets them all off. The use case (issue
                // #24) is MIDI-learn in a host like Ableton — disable every
                // dim, enable just the one you want to teach, then turn
                // everything back on with one tap.
                MasterEnableToggle(
                    allEnabled: allEnabled(isInput: isInput),
                    setAll: { on in setAllEnabled(on, isInput: isInput) }
                )
                .accessibilityIdentifier("mapping.all.\(isInput ? "input" : "output")")

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

    /// True iff every dim on the active tab is enabled. Used to drive the
    /// master toggle's checked state — an unchecked master means "at least
    /// one row is disabled" so tapping it re-enables everything.
    private func allEnabled(isInput: Bool) -> Bool {
        let arr = isInput ? viewModel.mappings.inputMappings
                          : viewModel.mappings.outputMappings
        return arr.allSatisfy { $0.enabled }
    }

    private func setAllEnabled(_ on: Bool, isInput: Bool) {
        if isInput {
            for i in viewModel.mappings.inputMappings.indices {
                viewModel.mappings.inputMappings[i].enabled = on
            }
        } else {
            for i in viewModel.mappings.outputMappings.indices {
                viewModel.mappings.outputMappings[i].enabled = on
            }
        }
        viewModel.saveMappings()
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
            // Per-row enable toggle. Unchecking suppresses both encode and
            // decode for this dimension — needed when teaching MIDI mappings
            // in a host that only learns the most-recent incoming message
            // (issue #24).
            EnableCheckbox(isOn: $mapping.enabled)
                .accessibilityIdentifier("mapping.row.\(dimensionIndex).enabled")

            // Dimension badge
            Text("\(dimensionIndex)")
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .opacity(mapping.enabled ? 1 : 0.4)

            // Message type. A Menu with a custom label (rather than a .menu
            // Picker) is used because Picker ignores .font / .lineLimit on its
            // displayed label — so "Note On" / "Pitch Bend" wrapped onto
            // multiple lines and overlapped neighbouring rows.
            Menu {
                Picker("Message Type", selection: $mapping.messageType) {
                    ForEach(MIDIMessageType.allCases, id: \.self) { type in
                        Text(type.displayName).tag(type)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(mapping.messageType.displayName)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.accentColor)
                .frame(width: 86, alignment: .leading)
            }

            Spacer(minLength: 0)

            // Channel (1–16). The note/CC number stepper is unlabelled —
            // the type picker already says which it is.
            CompactStepper(label: "Ch", value: $mapping.channel, range: 1...16)
            CompactStepper(label: nil, value: $mapping.number,
                           range: 0...127, enabled: mapping.messageType.usesNumber)
        }
    }
}

// MARK: - Compact Stepper

/// A tightly-packed −/value/+ control. Native `Stepper` is too wide to fit
/// two per row alongside a type picker on a phone-width screen.
private struct CompactStepper: View {
    let label: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            if let label {
                Text(label)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
            }

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

// MARK: - Enable Checkbox

/// SF Symbol-based checkbox, used per row. SwiftUI's `Toggle` defaults to a
/// large switch on iOS that would crowd the row, and `.toggleStyle(.checkbox)`
/// is macOS-only. A tappable square + checkmark renders the same on both
/// platforms.
private struct EnableCheckbox: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Master Enable Toggle

/// "All on / all off" row above the per-dimension list. Tapping flips every
/// row to the opposite of the current "all enabled" state.
private struct MasterEnableToggle: View {
    let allEnabled: Bool
    let setAll: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            EnableCheckbox(isOn: Binding(
                get: { allEnabled },
                set: { setAll($0) }
            ))
            Text(allEnabled ? "All dimensions enabled" : "Enable all dimensions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
