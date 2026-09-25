import XCTest
import CoreMIDI
// CoreMIDIBridge (host) and Common sources are compiled directly into this
// test target (see project.yml).

/// Round-trips real Core MIDI traffic into the bridge's "IMPSY In" virtual
/// destination and checks the exact bytes that reach the engine's input
/// buffer.
///
/// Regression test for the Release/App Store bug where `receive(eventList:)`
/// copied `eventList.pointee` and walked packets from a pointer escaping
/// `withUnsafePointer`: only the first packet was valid even in Debug, and
/// under -O all input was dropped or garbled. Run this suite with
/// `-configuration Release` too; the original bug only fully showed there.
final class CoreMIDIBridgeTests: XCTestCase {

    private var engine: InteractionEngine!
    private var bridge: CoreMIDIBridge!
    private var client: MIDIClientRef = 0
    private var outPort: MIDIPortRef = 0

    override func setUpWithError() throws {
        // Engine is never started, so nothing drains inputBuffer behind our back.
        engine = InteractionEngine(mappings: MIDIMappingSet.defaults(forModelDimension: 9))
        bridge = CoreMIDIBridge(engine: engine)
        bridge.start()
        guard bridge.isRunning, bridge.virtualDestination != 0 else {
            throw XCTSkip("Core MIDI unavailable: \(bridge.lastError ?? "unknown")")
        }
        XCTAssertEqual(MIDIClientCreate("IMPSY bridge test" as CFString, nil, nil, &client), noErr)
        XCTAssertEqual(MIDIOutputPortCreate(client, "test out" as CFString, &outPort), noErr)
    }

    override func tearDown() {
        bridge?.stop()
        if outPort != 0 { MIDIPortDispose(outPort) }
        if client  != 0 { MIDIClientDispose(client) }
        bridge = nil
        engine = nil
    }

    // MARK: - Tests

    func testSinglePacketListReachesInputBuffer() {
        send([[0xB0, 13, 42]])
        XCTAssertEqual(receive(expecting: 1), [[0xB0, 13, 42]])
    }

    func testEveryPacketInMultiPacketListReachesInputBuffer() {
        // Distinct timestamps make MIDIEventListAdd start a new packet per
        // message, which is what DAWs and USB devices commonly deliver.
        let messages: [[UInt8]] = [
            [0xB0, 13, 10], [0xB0, 14, 20], [0x90, 60, 100], [0xE0, 0x00, 0x40], [0x80, 60, 0],
        ]
        send(messages)
        XCTAssertEqual(receive(expecting: messages.count), messages)
    }

    func testManySinglePacketListsArriveInOrder() {
        let messages: [[UInt8]] = (0..<20).map { [0xB0, 13, UInt8($0 * 5)] }
        for message in messages { send([message]) }
        XCTAssertEqual(receive(expecting: messages.count), messages)
    }

    // MARK: - Helpers

    /// Sends each message as its own packet in one MIDIEventList.
    private func send(_ messages: [[UInt8]]) {
        var storage = [UInt8](repeating: 0, count: 4096)
        storage.withUnsafeMutableBytes { raw in
            let list = raw.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            var packet = MIDIEventListInit(list, ._1_0)
            let now = mach_absolute_time()
            for (i, message) in messages.enumerated() {
                var word: UInt32 = (0x2 << 28)
                    | (UInt32(message[0]) << 16)
                    | (UInt32(message[1]) << 8)
                    |  UInt32(message[2])
                packet = MIDIEventListAdd(list, raw.count, packet, now + UInt64(i), 1, &word)
                XCTAssertNotNil(packet, "event list overflow")
            }
            XCTAssertEqual(MIDISendEventList(outPort, bridge.virtualDestination, list), noErr)
        }
    }

    /// Polls the engine's input buffer until `count` packets arrive or 2 s pass.
    private func receive(expecting count: Int) -> [[UInt8]] {
        var received: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(2)
        while received.count < count, Date() < deadline {
            received += engine.inputBuffer.dequeueAll().map { p in
                [p.bytes.0, p.bytes.1, p.bytes.2]
            }
            if received.count < count { usleep(5_000) }
        }
        // Brief extra wait to catch spurious trailing packets.
        usleep(50_000)
        received += engine.inputBuffer.dequeueAll().map { [$0.bytes.0, $0.bytes.1, $0.bytes.2] }
        return received
    }
}
