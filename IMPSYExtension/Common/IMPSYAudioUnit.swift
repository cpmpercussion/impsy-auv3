import AudioToolbox
import AVFoundation
import CoreAudioKit

// MARK: - IMPSYAudioUnit
//
// AUAudioUnit subclass implementing an AUv3 MIDI Processor (type: aumi).
//
// MIDI flow:
//   Host → scheduleMIDIEventBlock → inputBuffer → InteractionEngine
//   InteractionEngine → outputBuffer → internalRenderBlock → midiOutputEventBlock → Host

public final class IMPSYAudioUnit: AUAudioUnit {

    // MARK: - Properties

    private(set) var engine: InteractionEngine
    var parameterTree_: AUParameterTree!

    // Non-parameter state (owned here; exposed via computed vars in +State extension)
    var _modelBookmarkData: Data?
    var _currentMappings = MIDIMappingSet.defaults(forModelDimension: 2)
    var _currentModelConfig: ModelConfig?
    var _currentModelDisplayName: String?

    /// Cached midiOutputEventBlock — captured in allocateRenderResources, used in render block.
    private var cachedMidiOutputBlock: AUMIDIOutputEventBlock?

    // MARK: - Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        // Build default engine with placeholder mappings (1 dimension)
        let defaultMappings = MIDIMappingSet.defaults(forModelDimension: 2)
        engine = InteractionEngine(mappings: defaultMappings)

        try super.init(componentDescription: componentDescription, options: options)

        setupParameterTree()
        setupEngineCallbacks()
        loadBundledDefaultModel()
    }

    // MARK: - AUAudioUnit Overrides

    public override var audioUnitName: String? { "IMPSY" }
    public override var audioUnitShortName: String? { "IMPSY" }

    public override var midiOutputNames: [String] { ["IMPSY Output"] }

    public override var parameterTree: AUParameterTree? {
        get { parameterTree_ }
        set { parameterTree_ = newValue }
    }

    public override var supportsUserPresets: Bool { true }

    // MARK: - Resources

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        cachedMidiOutputBlock = midiOutputEventBlock
        engine.start()
    }

    public override func deallocateRenderResources() {
        engine.stop()
        cachedMidiOutputBlock = nil
        super.deallocateRenderResources()
    }

    // MARK: - MIDI Input

    /// Block provided to the host so it can deliver MIDI events to this AU.
    public override var scheduleMIDIEventBlock: AUScheduleMIDIEventBlock? {
        let inputBuf = engine.inputBuffer
        return { (sampleTime: AUEventSampleTime, cable: UInt8, length: Int, data: UnsafePointer<UInt8>) in
            guard length >= 1 else { return }
            let b0 = data[0]
            let b1 = length > 1 ? data[1] : 0
            let b2 = length > 2 ? data[2] : 0
            inputBuf.enqueue(RawMIDIPacket(b0, b1, b2, length: min(length, 3)))
        }
    }

    // MARK: - Render Block

    public override var internalRenderBlock: AUInternalRenderBlock {
        let outputBuf = engine.outputBuffer
        return { [weak self] actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvents, pullInputBlock in
            guard let midiOut = self?.cachedMidiOutputBlock else { return noErr }
            // Drain any MIDI output events queued by the inference engine
            let packets = outputBuf.dequeueAll()
            for packet in packets {
                packet.withUnsafeBytes { ptr, length in
                    _ = midiOut(AUEventSampleTimeImmediate, 0, length, ptr)
                }
            }
            return noErr
        }
    }

    // MARK: - Private Setup

    private func setupEngineCallbacks() {
        engine.onStateChanged = { [weak self] state in
            // Post notification for UI to observe
            NotificationCenter.default.post(
                name: .IMPSYCallResponseStateChanged,
                object: self,
                userInfo: ["state": state.rawValue]
            )
        }
        engine.onEventGenerated = { [weak self] dt, events in
            let summary: String
            if let first = events.first {
                summary = events.count > 1 ? "\(first.summary) +\(events.count - 1)"
                                           : first.summary
            } else {
                summary = "—"
            }
            NotificationCenter.default.post(
                name: .IMPSYEventGenerated,
                object: self,
                userInfo: ["dt": dt, "summary": summary]
            )
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let IMPSYCallResponseStateChanged = Notification.Name("IMPSYCallResponseStateChanged")
    static let IMPSYModelStatusChanged       = Notification.Name("IMPSYModelStatusChanged")
    static let IMPSYEventGenerated           = Notification.Name("IMPSYEventGenerated")
}
