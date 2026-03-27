# IMPSY AUv3

AUv3 MIDI Processor plugin (type: `aumi`) for iOS 17+ and macOS 14+ that runs [IMPSY](https://github.com/cpmpercussion/impsy) MDRNN models in call-and-response mode. The sibling Python project lives at `../impsy`.

## Build setup

**Generate the Xcode project** (must be done after any `project.yml` change):
```bash
xcodegen generate
```

**TFLite dependency** — add manually in Xcode after generating:
- File → Add Package Dependencies → `https://github.com/google-ai-edge/LiteRT`
- Add to both `IMPSYExtension-iOS` and `IMPSYExtension-macOS` targets
- If using the `LiteRT` package, change `import TensorFlowLite` → `import LiteRT` in `TFLiteRNN.swift` and `ModelInspector.swift`

**Signing** — set Development Team on all 4 targets in Xcode after generating.

## Project structure

```
project.yml                          ← xcodegen spec (source of truth for Xcode project)
IMPSYExtension/Common/               ← shared by iOS + macOS extension targets
IMPSYExtension/iOS/                  ← iOS extension Info.plist + entitlements
IMPSYExtension/macOS/                ← macOS extension Info.plist + entitlements
IMPSYHost/iOS/                       ← container iOS app (required by App Store)
IMPSYHost/macOS/                     ← container macOS app
IMPSYUI/                             ← SwiftUI views + view model (shared by app + extension)
Tests/                               ← unit tests (run on macOS target)
```

## Key files and responsibilities

### Core logic (`IMPSYExtension/Common/`)

| File | Responsibility |
|------|---------------|
| `IMPSYParameters.swift` | `ParameterAddress` enum, defaults, ranges, `StateKey` constants |
| `MIDIMapping.swift` | `MIDIMessageType`, `DimensionMapping`, `MIDIMappingSet` — all `Codable` |
| `MIDIMapper.swift` | MIDI bytes ↔ normalised `[0,1]` Float conversion; `encodeOutput(values:)` / `denseUpdate(fromBytes:)` |
| `MDNSampler.swift` | Pure-Swift MDN sampling: softmax-with-temperature, categorical sampling, Box-Muller normal, post-processing (÷10, clamp, min dt) |
| `RingBuffer.swift` | `MIDIRingBuffer` — `os_unfair_lock`-based SPSC ring buffer for render-thread ↔ inference-queue hand-off |
| `ModelInspector.swift` | Reads `.tflite` tensor names/shapes → `ModelConfig { dimension, numLayers, hiddenUnits, numMixtures }` |
| `TFLiteRNN.swift` | Wraps TFLite `Interpreter`; manages LSTM states; `generate(input:piTemp:sigmaTemp:) -> [Float]` |
| `InteractionEngine.swift` | Call-and-response loop: 10ms `DispatchSourceTimer` on `"impsy.inference"` queue; drains input buffer, runs TFLiteRNN, schedules output via `asyncAfter` |
| `IMPSYAudioUnit.swift` | `AUAudioUnit` subclass; `scheduleMIDIEventBlock` (MIDI in → ring buffer); `internalRenderBlock` (drain output ring buffer → `midiOutputEventBlock`) |
| `IMPSYAudioUnit+Parameters.swift` | `AUParameterTree` with 4 parameters (threshold, sigmaTemp, piTemp, timescale) |
| `IMPSYAudioUnit+State.swift` | `fullState` serialization/restore; model loading from security-scoped bookmarks |
| `IMPSYAudioUnit+MIDI.swift` | `requestViewController` — returns `IMPSYViewController` |

### UI (`IMPSYUI/`)

| File | Responsibility |
|------|---------------|
| `IMPSYViewModel.swift` | `@MainActor ObservableObject`; bridges AU parameter tree ↔ SwiftUI; handles model loading and mapping saves |
| `IMPSYMainView.swift` | Root SwiftUI view + `IMPSYViewController` (iOS/macOS `AUViewController` subclass) |
| `ModelStatusView.swift` | Model filename, status indicator, Load button |
| `ParameterControlsView.swift` | Four sliders (threshold, sigmaTemp, piTemp, timescale) |
| `MappingEditorView.swift` | Segmented input/output tab + scrollable per-dimension mapping rows |
| `ModelPickerButton.swift` | `UIDocumentPickerViewController` (iOS) / `NSOpenPanel` (macOS) wrapped as SwiftUI button |

## Architecture: threading model

```
Render Thread (real-time, CoreAudio)
  MIDI in → scheduleMIDIEventBlock → MIDIRingBuffer (enqueue, lock-free fast path)
  MIDIRingBuffer (dequeue) → midiOutputEventBlock → MIDI out

Inference Queue (serial, .utility, "impsy.inference")
  DispatchSourceTimer @10ms
  → drain MIDIRingBuffer (input)
  → TFLiteRNN.generate() ~1–5ms
  → MDNSampler.sample()
  → DispatchQueue.asyncAfter(dt × timescale)
      → encode MIDI → MIDIRingBuffer (enqueue output)

Main Thread (@MainActor)
  SwiftUI, IMPSYViewModel, document picker
  model load → dispatched to inference queue (swaps TFLiteRNN atomically)
```

**Critical**: `TFLiteRNN` is not thread-safe — must only be called from the inference queue. The render block must never block (no locks that could be held by inference code longer than ~100µs).

## IMPSY model interface

TFLite models from `../impsy/models/` follow this tensor convention:

- **Inputs**: `inputs` (shape `1,1,dimension`), `state_h_N` / `state_c_N` per LSTM layer
- **Outputs**: MDN output (shape `1, numMixtures*(2*dimension+1)`), updated LSTM states
- **Scaling**: all values multiplied by `SCALE_FACTOR=10` before model input; divide by 10 on output
- **Dimension 0**: always time delta (seconds). Dimensions 1…N: normalised values in `[0,1]`
- **MDN output layout**: `[mus: M×D | sigmas: M×D | piLogits: M]`

The reference Python implementation is in `../impsy/impsy/mdrnn.py` (class `TfliteMDRNN`).

## AU registration

| Field | Value |
|-------|-------|
| Type | `aumi` (MIDI Processor) |
| Subtype | `impy` |
| Manufacturer | `CpM!` |
| Name | `Charles Martin: IMPSY` |
| Principal class | `IMPSYAudioUnit` |

## State persistence (`fullState`)

Non-automatable state lives in `fullState` (serialized by the host on session save):

| Key | Type | Content |
|-----|------|---------|
| `impsy.modelBookmark` | `Data` | Security-scoped URL bookmark |
| `impsy.inputMappings` | `Data` | JSON `[DimensionMapping]` |
| `impsy.outputMappings` | `Data` | JSON `[DimensionMapping]` |
| `impsy.threshold/sigmaTemp/piTemp/timescale` | `Float` | Parameter values |

The four parameters are also in the `AUParameterTree` (addresses 0–3) for host automation.

## AU Parameters

| Name | Address | Range | Default |
|------|---------|-------|---------|
| Threshold | 0 | 0.1–10.0 s | 2.0 |
| Sigma Temp | 1 | 0.001–2.0 | 0.01 |
| Pi Temp | 2 | 0.1–5.0 | 1.5 |
| Timescale | 3 | 0.1–4.0× | 1.0 |

## MIDI mapping conventions

- **Note On**: normalised = `velocity / 127.0`
- **CC**: normalised = `value / 127.0`
- **Pitch Bend**: normalised = `(rawValue + 8192) / 16383.0`
- Dimension IDs are 1-based (dim 0 is time, not user-configurable)
- Input and output mappings are independent (`MIDIMappingSet.inputMappings` / `.outputMappings`)

## Running tests

Tests require the macOS target. They are in `Tests/` and import `IMPSYExtension_macOS`. Live model tests (`ModelInspectorTests`) skip automatically if no `.tflite` file is found at `../impsy/models/`.

```bash
xcodebuild test -project IMPSY-AUv3.xcodeproj -scheme IMPSYTests -destination 'platform=macOS'
```

## Common tasks

**Regenerate Xcode project after editing `project.yml`:**
```bash
xcodegen generate
```

**Add a new AU parameter:**
1. Add case to `ParameterAddress` enum in `IMPSYParameters.swift`
2. Add defaults/ranges to `ParameterDefaults`/`ParameterRanges`
3. Add `createParameter` call in `IMPSYAudioUnit+Parameters.swift`
4. Handle in `implementorValueObserver` and `implementorValueProvider`
5. Add property to `InteractionEngine` and wire it up
6. Add `StateKey` and handle in `IMPSYAudioUnit+State.swift`
7. Add `@Published` property and sync in `IMPSYViewModel`

**Load a model for testing:**
Copy any `.tflite` from `../impsy/models/` to a location accessible via Files app, then use the Load Model button in the plugin UI.
