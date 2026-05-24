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
// Threading:
//   - Core MIDI's receive block runs on its own internal thread; it pushes
//     packets straight into the lock-protected input ring buffer.
//   - A serial DispatchSourceTimer on `drainQueue` drains the output ring
//     buffer and sends events out the virtual source. The interval is shorter
//     than the engine's 10ms inference tick so we don't add measurable delay.

final class CoreMIDIBridge {

    private weak var engine: InteractionEngine?
    private var client: MIDIClientRef = 0
    private var virtualSource: MIDIEndpointRef = 0       // bytes flow OUT of IMPSY
    private var virtualDestination: MIDIEndpointRef = 0  // bytes flow IN to IMPSY

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
        if virtualDestination != 0 { MIDIEndpointDispose(virtualDestination); virtualDestination = 0 }
        if virtualSource      != 0 { MIDIEndpointDispose(virtualSource);      virtualSource      = 0 }
        if client             != 0 { MIDIClientDispose(client);               client             = 0 }
        isRunning = false
    }

    // MARK: - Endpoint creation

    private func createClient() throws {
        let status = MIDIClientCreateWithBlock("IMPSY Host" as CFString, &client, nil)
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
        // A stable UID lets DAWs remember routing across launches. The string
        // form is hashed into the kMIDIPropertyUniqueID Int32 property.
        let uidInt: Int32 = Int32(truncatingIfNeeded: uid.hashValue)
        MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, uidInt)
        MIDIObjectSetStringProperty(endpoint, kMIDIPropertyManufacturer, "Charles Martin" as CFString)
        MIDIObjectSetStringProperty(endpoint, kMIDIPropertyModel, "IMPSY" as CFString)
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
