import SwiftUI

// MARK: - MIDIConnectionView
//
// Device pickers for connecting IMPSY to specific Core MIDI endpoints (#29) —
// e.g. a Roland S-1 over USB on iOS, or any IAC/hardware port on macOS. Lives
// on the Settings screen, but only when the standalone host has provided a
// `MIDIEndpointStore` (inside a DAW the host owns MIDI routing, so the AUv3
// extension never shows this).
//
// Selections persist across launches (by endpoint UID) and survive unplugs:
// an offline selection is shown greyed-out and reconnects automatically when
// the device reappears.

struct MIDIConnectionView: View {
    @ObservedObject var store: MIDIEndpointStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            endpointPicker(
                label: "Input",
                endpoints: store.sources,
                selectedUID: store.selectedSourceUID,
                accessibilityID: "midi.inputPicker"
            ) { store.selectSource(uid: $0) }

            endpointPicker(
                label: "Output",
                endpoints: store.destinations,
                selectedUID: store.selectedDestinationUID,
                accessibilityID: "midi.outputPicker"
            ) { store.selectDestination(uid: $0) }

            Text("Virtual ports IMPSY In / IMPSY Out are always available.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func endpointPicker(
        label: String,
        endpoints: [MIDIEndpointStore.Endpoint],
        selectedUID: Int32?,
        accessibilityID: String,
        onSelect: @escaping (Int32?) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Picker(label, selection: Binding(
                get: { selectedUID },
                set: { onSelect($0) }
            )) {
                Text("None").tag(Int32?.none)
                ForEach(endpoints) { endpoint in
                    Text(endpoint.name).tag(Int32?.some(endpoint.uid))
                }
                // Keep an offline selection visible (and re-selectable) even
                // though the device is currently absent — the bridge will
                // reconnect when it reappears.
                if let uid = selectedUID, !endpoints.contains(where: { $0.uid == uid }) {
                    Text("Offline device")
                        .foregroundStyle(.secondary)
                        .tag(Int32?.some(uid))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityIdentifier(accessibilityID)

            Spacer(minLength: 0)
        }
    }
}
