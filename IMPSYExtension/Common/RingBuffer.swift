import Foundation

// MARK: - Lock-based SPSC Ring Buffer
//
// A fixed-capacity circular buffer for passing small MIDI events from
// the render thread (producer) to the inference queue (consumer), and
// from the inference queue (producer) back to the render thread (consumer).
//
// Uses os_unfair_lock for correctness. The critical section is O(1) —
// typically < 500 ns — which is acceptable for audio render callbacks
// provided the inference queue does not hold the lock for extended periods.
//
// For a production implementation, replace with a true lock-free SPSC buffer
// (e.g. using Swift Atomics from https://github.com/apple/swift-atomics).

import os.lock

struct RawMIDIPacket {
    var bytes: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var length: Int = 0

    init(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, length: Int = 3) {
        bytes = (b0, b1, b2)
        self.length = length
    }

    func withUnsafeBytes<T>(_ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        var b = bytes
        return withUnsafeBytes(of: &b) { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), length)
        }
    }
}

final class MIDIRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var storage: [RawMIDIPacket]
    private var head: Int = 0
    private var tail: Int = 0
    private var lock = os_unfair_lock()

    init(capacity: Int = 256) {
        self.capacity = capacity
        self.storage = [RawMIDIPacket](repeating: RawMIDIPacket(0, 0, 0), count: capacity)
    }

    /// Enqueue a packet. Drops silently if full. Called from producer thread.
    func enqueue(_ packet: RawMIDIPacket) {
        os_unfair_lock_lock(&lock)
        let next = (tail + 1) % capacity
        if next != head {
            storage[tail] = packet
            tail = next
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Dequeue all available packets. Called from consumer thread.
    func dequeueAll() -> [RawMIDIPacket] {
        os_unfair_lock_lock(&lock)
        var result: [RawMIDIPacket] = []
        while head != tail {
            result.append(storage[head])
            head = (head + 1) % capacity
        }
        os_unfair_lock_unlock(&lock)
        return result
    }

    /// Non-blocking check for any queued items.
    var isEmpty: Bool {
        os_unfair_lock_lock(&lock)
        let empty = head == tail
        os_unfair_lock_unlock(&lock)
        return empty
    }
}
