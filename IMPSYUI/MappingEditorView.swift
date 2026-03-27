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
        VStack(alignment: .leading, spacing: 6) {
            // Tab picker for input/output
            Picker("Mapping", selection: $selectedTab) {
                ForEach(MappingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, 4)

            // Column headers
            HStack(spacing: 4) {
                Text("Dim").frame(width: 30, alignment: .center).font(.caption2).foregroundStyle(.secondary)
                Text("Type").frame(width: 90, alignment: .leading).font(.caption2).foregroundStyle(.secondary)
                Text("Ch").frame(width: 40, alignment: .center).font(.caption2).foregroundStyle(.secondary)
                Text("No.").frame(width: 50, alignment: .center).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                // Fader column header
                Text("Value").frame(width: 80, alignment: .center).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Divider()

            // Mapping rows
            let mappings = selectedTab == .input
                ? viewModel.mappings.inputMappings
                : viewModel.mappings.outputMappings

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(mappings.indices, id: \.self) { idx in
                        MappingRow(
                            dimensionIndex: idx + 1,
                            mapping: Binding(
                                get: {
                                    selectedTab == .input
                                        ? viewModel.mappings.inputMappings[safe: idx] ?? .defaults(forDimension: idx + 1)
                                        : viewModel.mappings.outputMappings[safe: idx] ?? .defaults(forDimension: idx + 1)
                                },
                                set: { newVal in
                                    if selectedTab == .input {
                                        viewModel.mappings.inputMappings[safe: idx] = newVal
                                    } else {
                                        viewModel.mappings.outputMappings[safe: idx] = newVal
                                    }
                                    viewModel.saveMappings()
                                }
                            )
                        )
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }
}

// MARK: - Single Mapping Row

private struct MappingRow: View {
    let dimensionIndex: Int
    @Binding var mapping: DimensionMapping

    var body: some View {
        HStack(spacing: 4) {
            // Dimension number
            Text("\(dimensionIndex)")
                .frame(width: 30, alignment: .center)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            // Message type picker
            Picker("", selection: $mapping.messageType) {
                ForEach(MIDIMessageType.allCases, id: \.self) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .frame(width: 90)
            .labelsHidden()

            // Channel stepper (1–16)
            Stepper(value: $mapping.channel, in: 1...16) {
                Text("\(mapping.channel)")
                    .frame(width: 24, alignment: .center)
                    .font(.system(.caption, design: .monospaced))
            }
            .frame(width: 40)

            // Number stepper (0–127), hidden for pitch bend
            if mapping.messageType.usesNumber {
                Stepper(value: $mapping.number, in: 0...127) {
                    Text("\(mapping.number)")
                        .frame(width: 36, alignment: .center)
                        .font(.system(.caption, design: .monospaced))
                }
                .frame(width: 50)
            } else {
                Spacer().frame(width: 50)
            }

            Spacer()
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Safe Array Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            if indices.contains(index), let value = newValue {
                self[index] = value
            }
        }
    }
}
