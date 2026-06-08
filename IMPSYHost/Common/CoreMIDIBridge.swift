import Foundation
import CoreMIDI

// MARK: - CoreMIDIBridge
//
// Exposes the standalone host app as a pair of Core MIDI virtual endpoints so
// DAWs that don't host AUv3 MIDI processors (e.g. Ableton Live) can route MIDI
// through IMPSY anyway. Wraps the in-process `InteractionEngine` ring buffers:
//
//   DAW ──► "IMPSY In" (virtual destination) ──► engine.inputBuffer
//   DAW ◄── "IMPSY Out" (virtual source) ◄────── engine.outputBuffer
//
// Naming is from IMPSY's perspective: "In" = bytes into IMPSY, "Out" = bytes
// from IMPSY. From the DAW's perspective these labels flip (IMPSY In appears
// as a MIDI output target; IMPSY Out as a MIDI input source) — that's standard
// for virtual MIDI ports.
//
// In addition to the always-on virtual ports, the bridge can connect directly
// to one hardware/IAC source and one destination (#29) — e.g. a Roland S-1
// over USB — selected via `MIDIEndpointStore` on the Settings screen:
//
//   device ──► input port (MIDIPortConnectSource) ──► engine.inputBuffer
//   device ◄── output port (MIDISendEventList) ◄───── engine.outputBuffer
//
// Selections persist in UserDefaults by endpoint UID and survive unplugs: a
// MIDI setup-change notification re-enumerates endpoints and reconnects when
// the chosen device reappears.
//
// Threading:
//   - Core MIDI's receive blocks run on their own internal thread; they push
//     packets straight into the lock-protected input ring buffer.
//   - A serial DispatchSourceTimer on `drainQueue` drains the output ring
//     buffer and sends events out the virtual source. The interval is shorter
//     than the engine's 10ms inference tick so we don't add measurable delay.
//   - Endpoint enumeration, selection, and store updates happen on the main
//     thread. `connectedDestination` crosses from main (reconcile) to
//     `drainQueue` (send) and is guarded by an os_unfair_lock.

final class CoreMIDIBridge {

    private weak var engine: InteractionEngine?
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0       // bytes flow OUT of IMPSY
    private var virtualDestination: MIDIEndpointRef = 0  // bytes flow IN to IMPSY

    // Direct device connections (#29). Desired UIDs are the source of truth
    // (persisted; kept across unplugs); connected refs reflect what is
    // currently live. Main-thread only, except `connectedDestination` which
    // the drain timer reads under `destinationLock`.
    private var inputPort:  MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var desiredSourceUID:      Int32?
    private var desiredDestinationUID: Int32?
    private var connectedSource: MIDIEndpointRef = 0
    private var connectedDestination: MIDIEndpointRef = 0   // guarded by destinationLock
    private var destinationLock = os_unfair_lock()
    private weak var store: MIDIEndpointStore?

    private enum DefaultsKey {
        static let inputUID  = "impsy.midi.inputDeviceUID"
        static let outputUID = "impsy.midi.outputDeviceUID"
    }

    private var drainTimer: DispatchSourceTimer?
    private let drainQueue = DispatchQueue(label: "impsy.midi-bridge.drain", qos: .userInitiated)

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(engine: InteractionEngine) {
        self.engine = engine
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        do {
            try createClient()
            try createVirtualDestination()
            try createVirtualSource()
            try createDevicePorts()
            restorePersistedSelections()
            startDrainTimer()
            isRunning = true
            lastError = nil
            NSLog("[IMPSY] CoreMIDIBridge: virtual ports active (IMPSY In / IMPSY Out)")
        } catch {
            lastError = error.localizedDescription
            NSLog("[IMPSY] CoreMIDIBridge: start failed: %@", String(describing: error))
            stop()
        }
    }

    func stop() {
        drainTimer?.cancel()
        drainTimer = nil
        if connectedSource != 0, inputPort != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
            connectedSource = 0
        }
        setConnectedDestination(0)
        if inputPort          != 0 { MIDIPortDispose(inputPort);              inputPort          = 0 }
        if outputPort         != 0 { MIDIPortDispose(outputPort);             outputPort         = 0 }
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination); virtualDestination = 0 }
        if virtualSource      != 0 { MIDIEndpointDispose(virtualSource);      virtualSource      = 0 }
        if client             != 0 { MIDIClientDispose(client);               client             = 0 }
        isRunning = false
    }

    // MARK: - Endpoint creation

    private func createClient() throws {
        let status = MIDIClientCreateWithBlock("IMPSY Host" as CFString, &client) { [weak self] notification in
            // Re-enumerate on hot-plug so the device pickers stay current and
            // a previously-selected device reconnects when it reappears.
            // CoreMIDI sends per-object added/removed notifications alongside
            // a single coalesced setup-changed; reacting only to the latter
            // avoids redundant rescans.
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            Task { @MainActor [weak self] in self?.handleSetupChanged() }
        }
        try check(status, "MIDIClientCreateWithBlock")
    }

    private func createVirtualDestination() throws {
        let status = MIDIDestinationCreateWithProtocol(
            client,
            "IMPSY In" as CFString,
            ._1_0,
            &virtualDestination
        ) { [weak self] eventListPtr, _ in
            self?.receive(eventList: eventListPtr)
        }
        try check(status, "MIDIDestinationCreateWithProtocol")
        setEndpointProperties(virtualDestination, uid: "au.charlesmartin.impsy.in")
    }

    private func createVirtualSource() throws {
        let status = MIDISourceCreateWithProtocol(
            client,
            "IMPSY Out" as CFString,
            ._1_0,
            &virtualSource
        )
        try check(status, "MIDISourceCreateWithProtocol")
        setEndpointProperties(virtualSource, uid: "au.charlesmartin.impsy.out")
    }

    private func setEndpointProperties(_ endpoint: MIDIEndpointRef, uid: String) {
        // A stable UID lets DAWs remember routing across launches. Swift's
        // String.hashValue is seeded randomly per process, so it can't be used
        // here — it would yield a different UID every launch. Hash the bytes
        // deterministically (FNV-1a) into the kMIDIPropertyUniqueID Int32 instead.
        MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, Self.stableUID(uid))
        MIDIObjectSetStringProperty(endpoint, kMIDIPropertyManufacturer, "Charles Martin" as CFString)
        MIDIObjectSetStringProperty(endpoint, kMIDIPropertyModel, "IMPSY" as CFString)
    }

    /// Deterministic 32-bit FNV-1a hash of a string, used as a stable CoreMIDI
    /// UID. Unlike `String.hashValue` this is identical across process launches.
    private static func stableUID(_ string: String) -> Int32 {
        var hash: UInt32 = 0x811c_9dc5            // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193            // FNV prime
        }
        // kMIDIPropertyUniqueID is Int32 and must be non-zero; FNV-1a of a
        // non-empty string is never the offset basis alone, so this is safe.
        return Int32(bitPattern: hash)
    }

    // MARK: - Device connections (#29)

    /// Ports for talking to user-selected endpoints. Created once at start;
    /// individual devices are connected/disconnected on the ports.
    private func createDevicePorts() throws {
        var status = MIDIInputPortCreateWithProtocol(
            client,
            "IMPSY Input" as CFString,
            ._1_0,
            &inputPort
        ) { [weak self] eventListPtr, _ in
            self?.receive(eventList: eventListPtr)
        }
        try check(status, "MIDIInputPortCreateWithProtocol")

        status = MIDIOutputPortCreate(client, "IMPSY Output" as CFString, &outputPort)
        try check(status, "MIDIOutputPortCreate")
    }

    private func restorePersistedSelections() {
        let defaults = UserDefaults.standard
        desiredSourceUID      = (defaults.object(forKey: DefaultsKey.inputUID)  as? Int).map(Int32.init(truncatingIfNeeded:))
        desiredDestinationUID = (defaults.object(forKey: DefaultsKey.outputUID) as? Int).map(Int32.init(truncatingIfNeeded:))
        Task { @MainActor [weak self] in self?.handleSetupChanged() }
    }

    /// Hand the UI store to the bridge. The bridge populates the endpoint
    /// lists and reacts to user selections; the store drives SwiftUI.
    @MainActor
    func attach(store: MIDIEndpointStore) {
        self.store = store
        store.onSelectSource      = { [weak self] uid in self?.setDesiredSource(uid: uid) }
        store.onSelectDestination = { [weak self] uid in self?.setDesiredDestination(uid: uid) }
        store.selectedSourceUID      = desiredSourceUID
        store.selectedDestinationUID = desiredDestinationUID
        handleSetupChanged()
    }

    @MainActor
    private func setDesiredSource(uid: Int32?) {
        desiredSourceUID = uid
        persist(uid, forKey: DefaultsKey.inputUID)
        reconcileConnections()
    }

    @MainActor
    private func setDesiredDestination(uid: Int32?) {
        desiredDestinationUID = uid
        persist(uid, forKey: DefaultsKey.outputUID)
        reconcileConnections()
    }

    private func persist(_ uid: Int32?, forKey key: String) {
        if let uid {
            UserDefaults.standard.set(Int(uid), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Rescan endpoints, refresh the UI store, and reconcile connections.
    /// Called at startup, on `attach`, and on every MIDI setup change.
    @MainActor
    private func handleSetupChanged() {
        guard client != 0 else { return }
        let sources      = enumerateEndpoints(count: MIDIGetNumberOfSources(),      at: MIDIGetSource,      excluding: virtualSource)
        let destinations = enumerateEndpoints(count: MIDIGetNumberOfDestinations(), at: MIDIGetDestination, excluding: virtualDestination)
        if let store {
            store.sources      = sources.map      { MIDIEndpointStore.Endpoint(uid: $0.uid, name: $0.name) }
            store.destinations = destinations.map { MIDIEndpointStore.Endpoint(uid: $0.uid, name: $0.name) }
        }
        reconcileConnections(sources: sources, destinations: destinations)
    }

    @MainActor
    private func reconcileConnections() {
        let sources      = enumerateEndpoints(count: MIDIGetNumberOfSources(),      at: MIDIGetSource,      excluding: virtualSource)
        let destinations = enumerateEndpoints(count: MIDIGetNumberOfDestinations(), at: MIDIGetDestination, excluding: virtualDestination)
        reconcileConnections(sources: sources, destinations: destinations)
    }

    /// Bring the live connections in line with the desired UIDs. A desired
    /// device that is currently absent simply stays disconnected — it will be
    /// picked up by the next setup-change rescan when it reappears.
    @MainActor
    private func reconcileConnections(sources: [EnumeratedEndpoint], destinations: [EnumeratedEndpoint]) {
        let sourceRef = desiredSourceUID.flatMap { uid in sources.first { $0.uid == uid }?.ref } ?? 0
        if sourceRef != connectedSource, inputPort != 0 {
            if connectedSource != 0 { MIDIPortDisconnectSource(inputPort, connectedSource) }
            connectedSource = sourceRef
            if sourceRef != 0 {
                let status = MIDIPortConnectSource(inputPort, sourceRef, nil)
                if status != noErr {
                    NSLog("[IMPSY] CoreMIDIBridge: MIDIPortConnectSource failed: %d", status)
                    connectedSource = 0
                }
            }
        }

        let destRef = desiredDestinationUID.flatMap { uid in destinations.first { $0.uid == uid }?.ref } ?? 0
        setConnectedDestination(destRef)
    }

    private func setConnectedDestination(_ ref: MIDIEndpointRef) {
        os_unfair_lock_lock(&destinationLock)
        connectedDestination = ref
        os_unfair_lock_unlock(&destinationLock)
    }

    private struct EnumeratedEndpoint {
        let ref: MIDIEndpointRef
        let uid: Int32
        let name: String
    }

    /// List endpoints of one kind, skipping IMPSY's own virtual port so the
    /// user can't route IMPSY's output back into its input.
    private func enumerateEndpoints(
        count: Int,
        at getter: (Int) -> MIDIEndpointRef,
        excluding own: MIDIEndpointRef
    ) -> [EnumeratedEndpoint] {
        (0..<count).compactMap { i in
            let ref = getter(i)
            guard ref != 0, ref != own else { return nil }
            var uid: Int32 = 0
            guard MIDIObjectGetIntegerProperty(ref, kMIDIPropertyUniqueID, &uid) == noErr else { return nil }
            return EnumeratedEndpoint(ref: ref, uid: uid, name: displayName(of: ref))
        }
    }

    private func displayName(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        // DisplayName combines device + endpoint names ("Roland S-1 MIDI IN");
        // fall back to the bare endpoint name for virtual ports that lack it.
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr,
           let value = name?.takeRetainedValue() {
            return value as String
        }
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &name) == noErr,
           let value = name?.takeRetainedValue() {
            return value as String
        }
        return "MIDI Device"
    }

    // MARK: - Input path (DAW → engine)

    private func receive(eventList: UnsafePointer<MIDIEventList>) {
        guard let engine = engine else { return }
        let list = eventList.pointee
        let count = Int(list.numPackets)
        guard count > 0 else { return }

        // First packet is embedded in the struct; subsequent ones are reached
        // via MIDIEventPacketNext. The packet tuple is C-style — walk by
        // pointer arithmetic.
        var packetPtr: UnsafePointer<MIDIEventPacket> = withUnsafePointer(to: list.packet) { $0 }
        for _ in 0..<count {
            processPacket(packetPtr, engine: engine)
            packetPtr = UnsafePointer(MIDIEventPacketNext(UnsafeMutablePointer(mutating: packetPtr)))
        }
    }

    private func processPacket(_ packetPtr: UnsafePointer<MIDIEventPacket>, engine: InteractionEngine) {
        let wordCount = Int(packetPtr.pointee.wordCount)
        guard wordCount > 0 else { return }

        // Walk the words tuple via raw-pointer rebinding.
        let wordsBase = UnsafeRawPointer(packetPtr).advanced(by: MemoryLayout<MIDITimeStamp>.size + MemoryLayout<UInt32>.size)
            .assumingMemoryBound(to: UInt32.self)

        var i = 0
        while i < wordCount {
            let word = wordsBase[i]
            let messageType = UInt8((word >> 28) & 0xF)
            let umpLength = umpWordLength(forMessageType: messageType)

            if messageType == 0x2 {
                // MIDI 1.0 Channel Voice — extract bytes from a single UMP word
                let status = UInt8((word >> 16) & 0xFF)
                let data1  = UInt8((word >>  8) & 0xFF)
                let data2  = UInt8( word        & 0xFF)
                let length = midiByteLength(forStatus: status)
                engine.inputBuffer.enqueue(RawMIDIPacket(status, data1, data2, length: length))
            }
            // Skip non-CV UMPs (utility, sysex, MIDI 2.0 CV, etc.) — IMPSY
            // only consumes MIDI 1.0 channel voice for mapping.

            i += max(umpLength, 1)
        }
    }

    // MARK: - Output path (engine → DAW)

    private func startDrainTimer() {
        let timer = DispatchSource.makeTimerSource(queue: drainQueue)
        timer.schedule(deadline: .now() + .milliseconds(5),
                       repeating: .milliseconds(5),
                       leeway:    .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainOutput() }
        drainTimer = timer
        timer.resume()
    }

    private func drainOutput() {
        guard let engine = engine, virtualSource != 0 else { return }
        let packets = engine.outputBuffer.dequeueAll()
        guard !packets.isEmpty else { return }

        // Buffer big enough for ~256 UMP words plus the MIDIEventList header.
        var storage = [UInt8](repeating: 0, count: 4096)
        storage.withUnsafeMutableBytes { raw in
            let listPtr = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            var packetPtr = MIDIEventListInit(listPtr, ._1_0)
            // Use the current host time so receivers don't treat the events
            // as expired (passing 0 caused intermittent drops in testing).
            let timestamp = mach_absolute_time()

            for pkt in packets {
                let word: UInt32 =
                    (UInt32(0x2) << 28) |          // MIDI 1.0 CV message type
                    (UInt32(0)   << 24) |          // group 0
                    (UInt32(pkt.bytes.0) << 16) |
                    (UInt32(pkt.bytes.1) <<  8) |
                     UInt32(pkt.bytes.2)
                var words = word
                packetPtr = MIDIEventListAdd(listPtr,
                                             raw.count,
                                             packetPtr,
                                             timestamp,
                                             1,
                                             &words)
            }

            let status = MIDIReceivedEventList(virtualSource, listPtr)
            if status != noErr {
                NSLog("[IMPSY] CoreMIDIBridge: MIDIReceivedEventList failed: %d", status)
            }

            // Also push the same list to the user-selected output device, if
            // any. Failures are expected transiently around unplug (until the
            // setup-change rescan clears the connection) — don't spam the log.
            os_unfair_lock_lock(&destinationLock)
            let destination = connectedDestination
            os_unfair_lock_unlock(&destinationLock)
            if destination != 0, outputPort != 0 {
                MIDISendEventList(outputPort, destination, listPtr)
            }
        }
    }

    // MARK: - UMP helpers

    /// Length in 32-bit words for each UMP message type (per MIDI 2.0 spec).
    private func umpWordLength(forMessageType mt: UInt8) -> Int {
        switch mt {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA, 0xD: return 2
        case 0xB, 0xC: return 3
        case 0x5, 0xF: return 4
        default: return 1
        }
    }

    /// Channel-voice MIDI 1.0 byte count for a given status byte.
    private func midiByteLength(forStatus status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 3
        case 0xC0, 0xD0:                   return 2
        default:                           return 3
        }
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else {
            throw NSError(domain: "IMPSY.CoreMIDIBridge",
                          code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "\(what) failed (OSStatus \(status))"])
        }
    }
}
