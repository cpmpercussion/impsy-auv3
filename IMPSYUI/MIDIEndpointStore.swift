import Foundation
import Combine

// MARK: - MIDIEndpointStore
//
// UI-facing model of the host's Core MIDI device connections. Deliberately
// free of CoreMIDI imports: IMPSYUI is compiled into the AUv3 extensions,
// which must not touch Core MIDI (inside a DAW the host owns MIDI routing).
// The standalone hosts create one of these and hand it to `CoreMIDIBridge`,
// which populates the endpoint lists and acts on selection changes. The
// extensions never create one, so the device-picker UI stays hidden there.
//
// Threading: all members are main-thread only (it drives SwiftUI).

@MainActor
final class MIDIEndpointStore: ObservableObject {

    /// One selectable Core MIDI endpoint. `uid` is the endpoint's
    /// kMIDIPropertyUniqueID — the only identifier that survives relaunches
    /// and USB re-plugs, so it's what selections persist as.
    struct Endpoint: Identifiable, Equatable {
        let uid: Int32
        let name: String
        var id: Int32 { uid }
    }

    // Available endpoints, refreshed by the bridge on every MIDI setup change.
    @Published var sources:      [Endpoint] = []   // devices IMPSY can listen to
    @Published var destinations: [Endpoint] = []   // devices IMPSY can send to

    // Selected endpoint UIDs (nil = none; virtual ports only). The selection
    // is kept even while the device is unplugged so it can auto-reconnect.
    @Published var selectedSourceUID:      Int32? = nil
    @Published var selectedDestinationUID: Int32? = nil

    // Set by CoreMIDIBridge. Called on the main thread when the user picks an
    // endpoint (or "None") from the UI.
    var onSelectSource:      ((Int32?) -> Void)?
    var onSelectDestination: ((Int32?) -> Void)?

    /// User picked an input device (nil = disconnect).
    func selectSource(uid: Int32?) {
        selectedSourceUID = uid
        onSelectSource?(uid)
    }

    /// User picked an output device (nil = disconnect).
    func selectDestination(uid: Int32?) {
        selectedDestinationUID = uid
        onSelectDestination?(uid)
    }
}
