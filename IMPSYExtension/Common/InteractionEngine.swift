import Foundation
import AudioToolbox

// MARK: - Call-Response State

enum CallResponseState: String {
    case call     = "CALL"       // User is playing; RNN listens
    case response = "RESPONSE"   // User has paused; RNN generates output
}

// MARK: - InteractionEngine
//
// Coordinates call-and-response interaction between MIDI input and the TFLite RNN.
//
// Threading:
//   - MIDI input arrives from the real-time render thread via enqueueInputPacket()
//   - A DispatchSourceTimer on `inferenceQueue` drains input, runs TFLiteRNN, and
//     schedules output packets back to `outputBuffer` with asyncAfter delays.
//   - The render thread drains `outputBuffer` and sends MIDI via midiOutputEventBlock.

final class InteractionEngine: @unchecked Sendable {

    // MARK: - Shared state (all mutations on inferenceQueue)

    private let inferenceQueue = DispatchQueue(label: "impsy.inference", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Model & mapper (replaced atomically on inferenceQueue)
    private var rnn: TFLiteRNN?
    private var mapper: MIDIMapper

    // Dense input vector: index 0-based (dim 1 → index 0, etc.), length = dimension-1
    private var inputVector: [Float] = []

    // Current call-response state
    private(set) var callResponseState: CallResponseState = .call
    private var lastUserInputTime: Double = 0

    // MARK: - Parameters (read on inferenceQueue, written from any thread)

    var threshold: Double = Double(ParameterDefaults.threshold)
    var sigmaTemp: Float  = ParameterDefaults.sigmaTemp
    var piTemp: Float     = ParameterDefaults.piTemp
    var timescale: Float  = ParameterDefaults.timescale

    // MARK: - Ring buffers

    let inputBuffer  = MIDIRingBuffer(capacity: 256)
    let outputBuffer = MIDIRingBuffer(capacity: 256)

    // MARK: - State change notification (called on main thread)

    var onStateChanged: ((CallResponseState) -> Void)?

    // MARK: - Init

    init(mappings: MIDIMappingSet) {
        self.mapper = MIDIMapper(mappings: mappings)
    }

    // MARK: - Lifecycle

    func start() {
        inferenceQueue.async { [weak self] in
            self?.startTimer()
        }
    }

    func stop() {
        inferenceQueue.sync { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // MARK: - MIDI Input (called from render thread)

    /// Enqueue a raw MIDI packet from the render thread.
    func enqueueInputPacket(_ packet: RawMIDIPacket) {
        inputBuffer.enqueue(packet)
    }

    // MARK: - Model Loading (call from any thread; dispatches to inferenceQueue)

    func loadModel(url: URL, config: ModelConfig) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let newRNN = try TFLiteRNN(modelURL: url, config: config)
                self.rnn = newRNN
                self.inputVector = [Float](repeating: 0, count: config.dimension - 1)
            } catch {
                print("[IMPSY] Failed to load model: \(error)")
                self.rnn = nil
            }
        }
    }

    func clearModel() {
        inferenceQueue.async { [weak self] in
            self?.rnn = nil
            self?.inputVector = []
        }
    }

    func resetLSTMStates() {
        inferenceQueue.async { [weak self] in
            self?.rnn?.resetStates()
        }
    }

    // MARK: - Mapping Updates (call from main/UI thread)

    func updateMappings(_ mappings: MIDIMappingSet) {
        inferenceQueue.async { [weak self] in
            self?.mapper.mappings = mappings
        }
    }

    // MARK: - Private: Timer & Inference Loop

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: inferenceQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        // ── Drain MIDI input ──────────────────────────────────────────────────
        let packets = inputBuffer.dequeueAll()
        var gotUserInput = false

        for packet in packets {
            packet.withUnsafeBytes { ptr, length in
                if let (index, value) = mapper.denseUpdate(fromBytes: ptr, length: length) {
                    // index is 0-based; resize vector if needed
                    if index < inputVector.count {
                        inputVector[index] = value
                    }
                    gotUserInput = true
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime
        if gotUserInput {
            lastUserInputTime = now
        }

        // ── Determine call/response state ─────────────────────────────────────
        let timeSinceInput = now - lastUserInputTime
        let newState: CallResponseState = timeSinceInput > threshold ? .response : .call

        if newState != callResponseState {
            callResponseState = newState
            let stateForCallback = newState
            DispatchQueue.main.async { [weak self] in
                self?.onStateChanged?(stateForCallback)
            }
        }

        // ── Run inference in response mode ────────────────────────────────────
        guard callResponseState == .response, let rnn else { return }

        do {
            // Build model input: [dt_placeholder=0, x_1, x_2, ..., x_N]
            var modelInput = [Float(0.0)] + inputVector   // dt = 0 when feeding input
            // Note: in IMPSY call-response, we feed the last user input to seed the RNN
            // then let it feed back to itself

            let output = try rnn.generate(
                input:     modelInput,
                piTemp:    piTemp,
                sigmaTemp: sigmaTemp
            )

            // output[0] = dt (seconds until next event)
            // output[1...] = normalised values for each dimension
            let dt = Double(output[0]) * Double(timescale)
            let values = Array(output.dropFirst())   // 0-based, length = dimension-1

            // Feed RNN output back to itself on next tick (update inputVector)
            inputVector = values

            // Schedule MIDI output after dt seconds
            let events = mapper.encodeOutput(values: values)
            let deadline = DispatchTime.now() + dt
            DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: deadline) { [weak self] in
                guard let self else { return }
                for event in events {
                    self.outputBuffer.enqueue(
                        RawMIDIPacket(event.statusByte, event.data1, event.data2, length: event.byteCount)
                    )
                }
            }
        } catch {
            print("[IMPSY] Inference error: \(error)")
        }
    }
}
