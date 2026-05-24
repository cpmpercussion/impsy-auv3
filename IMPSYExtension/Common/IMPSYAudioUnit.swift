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

    // Session-logging state (folder bookmark + on/off + display path)
    var _logFolderBookmarkData: Data?
    var _logFolderDisplayPath: String?
    var _loggingEnabled: Bool = false
    let sessionLogger = SessionLogger()

    /// Cached midiOutputEventBlock — captured in allocateRenderResources, used in render block.
    private var cachedMidiOutputBlock: AUMIDIOutputEventBlock?

    /// Audio busses. A MIDI processor produces no audio, but a host — and the
    /// out-of-process AUv3 bridge in particular — requires a valid output bus,
    /// otherwise allocateRenderResources fails with -10875.
    private var _outputBusArray: AUAudioUnitBusArray!
    private var _inputBusArray:  AUAudioUnitBusArray!

    // MARK: - Init

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        // Build default engine with placeholder mappings (1 dimension)
        let defaultMappings = MIDIMappingSet.defaults(forModelDimension: 2)
        engine = InteractionEngine(mappings: defaultMappings)

        try super.init(componentDescription: componentDescription, options: options)

        // A valid output bus is required for the AU to initialise, especially
        // when loaded out of process. The render block fills it with silence.
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let outputBus = try AUAudioUnitBus(format: format)
        _outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        _inputBusArray  = AUAudioUnitBusArray(audioUnit: self, busType: .input,  busses: [])

        setupParameterTree()
        setupEngineCallbacks()
        engine.logger = sessionLogger
        loadBundledDefaultModel()
    }

    // MARK: - Audio Busses

    public override var inputBusses:  AUAudioUnitBusArray { _inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusArray }

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
        let inputBuf  = engine.inputBuffer
        let outputBuf = engine.outputBuffer
        return { [weak self] actionFlags, timestamp, frameCount, outputBusNumber, outputData, renderEvents, pullInputBlock in
            // This AU produces no audio — fill the output bus with silence.
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            // Drain incoming MIDI from the render-events linked list. Many AUv3
            // hosts (AUM included) deliver MIDI here for sample-accurate timing
            // rather than via scheduleMIDIEventBlock, so we have to walk it.
            var evPtr = renderEvents
            while let event = evPtr {
                let header = event.pointee.head
                if header.eventType == .MIDI {
                    let midi = event.pointee.MIDI
                    let length = min(Int(midi.length), 3)
                    if length >= 1 {
                        let d = midi.data
                        let b1: UInt8 = length > 1 ? d.1 : 0
                        let b2: UInt8 = length > 2 ? d.2 : 0
                        inputBuf.enqueue(RawMIDIPacket(d.0, b1, b2, length: length))
                    }
                }
                evPtr = header.next.map { UnsafePointer($0) }
            }
            // Drain any MIDI output events queued by the inference engine.
            if let midiOut = self?.cachedMidiOutputBlock {
                for packet in outputBuf.dequeueAll() {
                    packet.withUnsafeBytes { ptr, length in
                        _ = midiOut(AUEventSampleTimeImmediate, 0, length, ptr)
                    }
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
        engine.onEventGenerated = { [weak self] dt, events, values in
            let summary: String
            if let first = events.first {
                summary = events.count > 1 ? "\(first.summary) +\(events.count - 1)"
                                           : first.summary
            } else {
                summary = "—"
            }
            // Dimension indices (still passed for the per-dim LEDs) are just
            // 0..<events.count; values are the actual per-dim normalised
            // outputs from the RNN, used by the dashboard faders.
            let dims = Array(0..<events.count)
            NotificationCenter.default.post(
                name: .IMPSYEventGenerated,
                object: self,
                userInfo: [
                    "dt": dt,
                    "summary": summary,
                    "dimensions": dims,
                    "values": values,
                ]
            )
        }
        engine.onUserInputReceived = { [weak self] dim in
            NotificationCenter.default.post(
                name: .IMPSYUserInputReceived,
                object: self,
                userInfo: ["dimension": dim]
            )
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let IMPSYCallResponseStateChanged = Notification.Name("IMPSYCallResponseStateChanged")
    static let IMPSYModelStatusChanged       = Notification.Name("IMPSYModelStatusChanged")
    static let IMPSYEventGenerated           = Notification.Name("IMPSYEventGenerated")
    static let IMPSYUserInputReceived        = Notification.Name("IMPSYUserInputReceived")
    static let IMPSYLogFolderChanged         = Notification.Name("IMPSYLogFolderChanged")
}
