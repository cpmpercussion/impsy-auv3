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

    // Last complete user interaction fed to the RNN: [dt, v_1 … v_N], length = dimension.
    // Used to prime the response chain when the engine switches to response mode.
    private var lastUserInteraction: [Float] = []

    // Current call-response state
    private(set) var callResponseState: CallResponseState = .call
    private var lastUserInputTime: Double = 0

    // Monotonic token identifying the current response chain. Bumped whenever
    // the engine leaves response mode or the model changes; an in-flight chain
    // whose token no longer matches stops itself.
    private var responseGeneration: Int = 0

    // MARK: - Parameters (read on inferenceQueue, written from any thread)

    var threshold: Double = Double(ParameterDefaults.threshold)
    var sigmaTemp: Float  = ParameterDefaults.sigmaTemp
    var piTemp: Float     = ParameterDefaults.piTemp
    var timescale: Float  = ParameterDefaults.timescale
    var inputThru: Bool   = ParameterDefaults.inputThru > 0.5

    // MARK: - Ring buffers

    let inputBuffer  = MIDIRingBuffer(capacity: 256)
    let outputBuffer = MIDIRingBuffer(capacity: 256)

    // MARK: - State change notification (called on main thread)

    var onStateChanged: ((CallResponseState) -> Void)?

    /// Called on the inference queue each time a response event is emitted,
    /// with the event's `dt` (seconds), the MIDI it produced, and the
    /// per-output-dimension normalised values that produced those events
    /// (`values[i]` corresponds to dimension `i+1`). Used purely for UI
    /// activity feedback and the dashboard faders.
    var onEventGenerated: ((Double, [MIDIEvent], [Float]) -> Void)?

    /// Called on the inference queue for each mapped user MIDI event drained
    /// from the input buffer, with its 0-based dimension index. Used purely for
    /// UI activity feedback (ACT LED + per-dimension indicators).
    var onUserInputReceived: ((Int) -> Void)?

    // MARK: - Init

    init(mappings: MIDIMappingSet) {
        self.mapper = MIDIMapper(mappings: mappings)
    }

    // MARK: - Lifecycle

    func start() {
        inferenceQueue.async { [weak self] in
            // Idempotent: a real host calls allocateRenderResources() (which
            // starts the engine); the test host starts it directly.
            guard let self, self.timer == nil else { return }
            self.startTimer()
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

    /// Swap in a new RNN built from in-memory model bytes.
    ///
    /// The caller is responsible for reading the bytes from a security-scoped
    /// URL — by the time this runs on `inferenceQueue` the source URL may no
    /// longer be accessible, so we never hold one across that boundary.
    func loadModel(modelData: Data, displayName: String, config: ModelConfig) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let newRNN = try TFLiteRNN(modelData: modelData, config: config)
                self.flushAllNoteOffs()
                self.rnn = newRNN
                // Match the IMPSY Python reference (impsy/interaction.py): seed the
                // first interaction with a random sample so response mode primes from
                // plausible musical state when it triggers before any user input.
                let initial = Self.randomInitialSample(dimension: config.dimension)
                self.inputVector = Array(initial.dropFirst())
                self.lastUserInteraction = initial
                // Cancel any response chain running against the previous model
                // and start fresh in call mode.
                self.responseGeneration &+= 1
                self.callResponseState = .call
                self.lastUserInputTime = ProcessInfo.processInfo.systemUptime
                NSLog("[IMPSY] InteractionEngine: RNN ready for %@", displayName)
            } catch {
                NSLog("[IMPSY] InteractionEngine: failed to load model: %@",
                      String(describing: error))
                self.rnn = nil
            }
        }
    }

    func clearModel() {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.flushAllNoteOffs()
            self.rnn = nil
            self.inputVector = []
            // Cancel any in-flight response chain.
            self.responseGeneration &+= 1
        }
    }

    func resetLSTMStates() {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            self.flushAllNoteOffs()
            self.rnn?.resetStates()
            // After zeroing the LSTM, drive one random sample through the RNN so
            // it leaves blank state before any response generation. Same seed shape
            // as IMPSY's random_sample(): dt ≈ 0.01 s jittered, values in [0,1).
            if let rnn = self.rnn, !self.lastUserInteraction.isEmpty {
                let initial = Self.randomInitialSample(dimension: self.lastUserInteraction.count)
                _ = try? rnn.generate(input: initial,
                                      piTemp: self.piTemp,
                                      sigmaTemp: self.sigmaTemp)
                self.inputVector = Array(initial.dropFirst())
                self.lastUserInteraction = initial
            }
            // Cancel any in-flight response chain so it doesn't keep generating
            // from the pre-reset seed.
            self.responseGeneration &+= 1
            // If we were already responding when reset hit, the cancelled chain
            // won't restart on its own — `tick()` only spawns a new chain on
            // the .call → .response transition. Kick off a fresh chain with
            // the post-reset seed so predictions keep flowing.
            if self.callResponseState == .response {
                self.generateAndScheduleResponse(seed: self.lastUserInteraction,
                                                 generation: self.responseGeneration)
            }
        }
    }

    // MARK: - Initial Sample
    //
    // Mirrors `random_sample` in ../impsy/impsy/mdrnn.py: dimension 0 is a small
    // dt (≈ 0.0075–0.0125 s) and the remaining dimensions are random in [0,1).
    static func randomInitialSample(dimension: Int) -> [Float] {
        guard dimension > 0 else { return [] }
        var sample = (0..<dimension).map { _ in Float.random(in: 0..<1) }
        sample[0] = 0.01 + (Float.random(in: 0..<1) - 0.5) * 0.005
        return sample
    }

    // MARK: - Mapping Updates (call from main/UI thread)

    func updateMappings(_ mappings: MIDIMappingSet) {
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            // Output mappings may move notes to different channels; flush any
            // outstanding notes against the old mappings so they do not hang.
            self.flushAllNoteOffs()
            self.mapper.mappings = mappings
        }
    }

    // MARK: - Private: Timer & Inference Loop

    private func startTimer() {
        // Treat startup as a fresh user interaction so the engine begins in
        // call mode rather than immediately crossing the response threshold.
        lastUserInputTime = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: inferenceQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// 10 ms housekeeping tick: drains MIDI input, lets the RNN "listen" while
    /// the user is playing, and watches for the call ⇄ response transition.
    ///
    /// Response-mode generation is deliberately NOT driven from here. Once in
    /// response mode the RNN feeds itself: each prediction schedules the next
    /// one after its own predicted `dt` (see `generateAndScheduleResponse`).
    /// Running the RNN on every 10 ms tick — the previous behaviour — produced
    /// ~100 predictions/second regardless of the model's intended timing.
    private func tick() {
        // ── Drain MIDI input ──────────────────────────────────────────────────
        let packets = inputBuffer.dequeueAll()
        var gotUserInput = false
        var touchedDimensions: [Int] = []

        for packet in packets {
            packet.withUnsafeBytes { ptr, length in
                if let (index, value) = mapper.denseUpdate(fromBytes: ptr, length: length) {
                    // index is 0-based into the user value dimensions
                    if index < inputVector.count {
                        inputVector[index] = value
                    }
                    touchedDimensions.append(index)
                    gotUserInput = true
                }
            }
        }

        let now = ProcessInfo.processInfo.systemUptime

        // ── User input: record it and let the RNN listen ─────────────────────
        if gotUserInput {
            for dim in touchedDimensions {
                onUserInputReceived?(dim)
            }
            let dt = max(now - lastUserInputTime, IMPSYConstants.minimumDeltaTime)
            lastUserInputTime = now
            // Full interaction vector consumed by the RNN: [dt, v_1 … v_N].
            lastUserInteraction = [Float(dt)] + inputVector

            // In call mode the RNN consumes user input purely to advance its
            // LSTM state — the generated output is intentionally discarded so
            // the model has musical context once it takes over in response mode.
            if callResponseState == .call, let rnn {
                _ = try? rnn.generate(input: lastUserInteraction,
                                      piTemp: piTemp, sigmaTemp: sigmaTemp)
            }

            // MIDI thru: re-encode the current input vector through the
            // output mappings (mirrors `send_back_values` in
            // ../impsy/impsy/interaction.py). One emission per tick — the
            // vector already reflects the latest value per dimension.
            if inputThru {
                let events = mapper.encodeOutput(values: inputVector)
                for event in events {
                    outputBuffer.enqueue(
                        RawMIDIPacket(event.statusByte, event.data1, event.data2,
                                      length: event.byteCount)
                    )
                }
            }
        }

        // ── Call ⇄ response transition ───────────────────────────────────────
        let timeSinceInput = now - lastUserInputTime
        let newState: CallResponseState = timeSinceInput > threshold ? .response : .call
        guard newState != callResponseState else { return }

        callResponseState = newState
        let stateForCallback = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChanged?(stateForCallback)
        }

        switch newState {
        case .response:
            // Start a fresh response chain primed with the last user interaction.
            responseGeneration &+= 1
            generateAndScheduleResponse(seed: lastUserInteraction,
                                        generation: responseGeneration)
        case .call:
            // Cancel the in-flight response chain: any pending generation sees
            // the bumped token and stops.
            responseGeneration &+= 1
            // The last RNN-emitted note would otherwise hang on the receiving
            // synth until the next response chain plays another one.
            flushAllNoteOffs()
        }
    }

    /// Drain note_off events for every channel with an outstanding note_on
    /// straight into the output ring buffer. Must be called on `inferenceQueue`.
    private func flushAllNoteOffs() {
        for event in mapper.releaseAllNotes() {
            outputBuffer.enqueue(
                RawMIDIPacket(event.statusByte, event.data1, event.data2,
                              length: event.byteCount)
            )
        }
    }

    /// One link in the self-feeding response loop: generate a single RNN event
    /// from `seed`, schedule its MIDI output after the predicted `dt`, and —
    /// once that fires — recurse to produce the next event. The loop's pacing
    /// comes from each prediction's own `dt`, mirroring IMPSY's `playback_rnn_loop`.
    ///
    /// - Parameters:
    ///   - seed: Input vector `[dt, v_1 … v_N]` in real units.
    ///   - generation: Token captured when this chain started. If it no longer
    ///     matches `responseGeneration`, the chain has been cancelled and stops.
    private func generateAndScheduleResponse(seed: [Float], generation: Int) {
        guard callResponseState == .response,
              generation == responseGeneration,
              let rnn else { return }

        let output: [Float]
        do {
            output = try rnn.generate(input: seed, piTemp: piTemp, sigmaTemp: sigmaTemp)
        } catch {
            print("[IMPSY] Inference error: \(error)")
            return
        }

        // output[0] = dt (seconds until this event), output[1…] = values in [0,1].
        let dt = Double(output[0]) * Double(timescale)
        let values = Array(output.dropFirst())
        let events = mapper.encodeOutput(values: values)

        // The next prediction is seeded with this event. Matching interaction.py,
        // the timescaled dt is what gets fed back into the RNN.
        let nextSeed = [Float(dt)] + values

        inferenceQueue.asyncAfter(deadline: .now() + dt) { [weak self] in
            guard let self,
                  self.callResponseState == .response,
                  generation == self.responseGeneration else { return }

            // Emit this event's MIDI…
            for event in events {
                self.outputBuffer.enqueue(
                    RawMIDIPacket(event.statusByte, event.data1, event.data2,
                                  length: event.byteCount)
                )
            }
            // …notify the UI. `values` is one entry per output dimension
            // (index 0 = dim 1) in the same order as `events`, so the UI can
            // both flash per-dim LEDs and update fader positions.
            self.onEventGenerated?(dt, events, values)
            // …then generate the event that follows it.
            self.generateAndScheduleResponse(seed: nextSeed, generation: generation)
        }
    }
}
