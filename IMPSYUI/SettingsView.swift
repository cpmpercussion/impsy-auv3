import SwiftUI

// MARK: - Settings View
//
// Configuration screen: load a model and tweak the inference parameters. The
// existing `ModelStatusView` and `ParameterControlsView` are reused so the
// behaviour is identical to the pre-split single view.

struct SettingsView: View {
    @ObservedObject var viewModel: IMPSYViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Model")
                ModelStatusView(viewModel: viewModel)
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Parameters")
                ParameterControlsView(viewModel: viewModel)
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Dedup")
                DedupControlsView(viewModel: viewModel)
            }

            // Device pickers exist only in the standalone hosts — the store
            // is nil inside the AUv3 extension (the DAW owns MIDI routing).
            if let midiStore = viewModel.midiEndpointStore {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("MIDI Devices")
                    MIDIConnectionView(store: midiStore)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Configuration")
                ConfigPickerControls(viewModel: viewModel)
            }

            VStack(alignment: .leading, spacing: 4) {
                sectionLabel("Logging")
                LoggingControlsView(viewModel: viewModel)
            }

            Spacer(minLength: 0)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}
