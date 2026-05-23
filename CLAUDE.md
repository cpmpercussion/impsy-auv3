# IMPSY AUv3

AUv3 MIDI Processor plugin (type: `aumi`) for iOS 17+ and macOS 14+ that runs [IMPSY](https://github.com/cpmpercussion/impsy) MDRNN models in call-and-response mode. The sibling Python project lives at `../impsy`.

## Build setup

**Generate the Xcode project** (must be done after any `project.yml` change):
```bash
xcodegen generate
```

**Build the TFLite xcframework** (must be done once after cloning, and after any change to `scripts/build_tflite_xcframework.sh`):
```bash
./scripts/build_tflite_xcframework.sh
```

**TFLite dependency** — vended through `Packages/TensorFlowLite`, a local Swift package wired up by xcodegen. Linked into all four app/extension targets and the test target (the host must embed it so the extension can load it).
- The Swift wrapper sources under `Packages/TensorFlowLite/Sources/TensorFlowLite/` are vendored from `kewlbear/TensorFlowLiteSwift` (Apache 2.0).
- The binary `TensorFlowLiteC.xcframework` is **not committed** — it is assembled by `scripts/build_tflite_xcframework.sh` from:
  - iOS slices: kewlbear's `TensorFlowLiteC.xcframework.zip` release (v2.14.0, packaged as `0.0.20250619`).
  - macOS arm64 slice: `tphakala/tflite_c` v2.17.1 darwin_arm64 dylib, repacked as a versioned framework with deployment target lowered via `vtool` to match the project's macOS 14.0 minimum and headers/modulemap copied from the iOS slice (TFLite C ABI is stable across 2.14↔2.17).
- macOS support is **Apple Silicon only**. There is no reliable v2.17.1 darwin_amd64 prebuilt; supporting Intel Macs would require building TFLite from source.
- Use `import TensorFlowLite` in `TFLiteRNN.swift` and `ModelInspector.swift`.

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
Packages/TensorFlowLite/             ← local Swift package vending TFLite (binary xcframework + Swift wrapper)
Tests/                               ← unit tests (run on macOS target)
scripts/build_tflite_xcframework.sh  ← assembles Packages/TensorFlowLite/Frameworks/TensorFlowLiteC.xcframework
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

### Initialisation parity with IMPSY Python

The engine initialises to match `../impsy/impsy/mdrnn.py` and `interaction.py`:
- **LSTM h/c states**: zero-initialised (`lstm_blank_states` in Python, `TFLiteRNN.lstmStates` in Swift).
- **First interaction vector**: a *random sample* — `dt ≈ 0.01 s` plus random `[0,1)` values — produced by `InteractionEngine.randomInitialSample(dimension:)`, mirroring `random_sample()` in Python. This only matters when response mode triggers before any user input; once the user plays, the vector is overwritten with real MIDI.

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
| `impsy.threshold/sigmaTemp/piTemp/timescale/inputThru` | `Float` | Parameter values |

The five parameters are also in the `AUParameterTree` (addresses 0–4) for host automation.

## AU Parameters

| Name | Address | Range | Default |
|------|---------|-------|---------|
| Threshold | 0 | 0.1–10.0 s | 0.1 |
| Sigma Temp | 1 | 0.001–2.0 | 0.01 |
| Pi Temp | 2 | 0.1–5.0 | 1.0 |
| Timescale | 3 | 0.1–4.0× | 1.0 |
| MIDI Thru | 4 | 0 / 1 (boolean) | 1 (on) |

**MIDI Thru** mirrors `input_thru` in IMPSY Python (`../impsy/impsy/interaction.py:415`): when on, every mapped user MIDI input re-encodes the current input vector through the output mappings and emits MIDI immediately, in addition to feeding the RNN. Turn off when the user's controller already drives the synth directly.

Defaults match `configs/AiC-charles-u6midipro.toml` in the IMPSY repo.

## MIDI mapping conventions

- **Note On**: normalised = `velocity / 127.0`
- **CC**: normalised = `value / 127.0`
- **Pitch Bend**: normalised = `(rawValue + 8192) / 16383.0`
- Dimension IDs are 1-based (dim 0 is time, not user-configurable)
- Input and output mappings are independent (`MIDIMappingSet.inputMappings` / `.outputMappings`)

## Running tests

Tests run on the macOS target. They are in `Tests/` and are bundled into the `IMPSYTests` target. `testInspectBundledSmallModel` exercises end-to-end TFLite inference against a small `.tflite` fixture shipped with the test bundle, so it doubles as a smoke test that the macOS xcframework loads correctly. The pair of `testInspectRealModel` / `testInspectSmallModel` tests look for models at `../impsy/models/` and skip otherwise.

```bash
xcodebuild test -project IMPSY-AUv3.xcodeproj -scheme IMPSYHost-macOS -destination 'platform=macOS'
```

## Common tasks

**Regenerate Xcode project after editing `project.yml`:**
```bash
xcodegen generate
```

**Rebuild the TFLite xcframework** (after editing `scripts/build_tflite_xcframework.sh` or bumping versions):
```bash
./scripts/build_tflite_xcframework.sh
```
The script is also run by `ci_scripts/ci_post_clone.sh` so Xcode Cloud builds pick up a fresh xcframework before SPM resolution.

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

**Refresh the macOS AU registration:**
```bash
./scripts/refresh-au-registration.sh          # auto: /Applications if present, else latest Debug
./scripts/refresh-au-registration.sh debug    # force the local Debug build
./scripts/refresh-au-registration.sh --dry-run
```
LaunchServices clings to stale extension paths from Xcode archives and old DerivedData builds. PluginKit may dispatch to a deleted path, and the host (Logic / Ableton / `auval`) gets `OpenAComponent -10810` ("Failed to load Audio Unit 'IMPSY'"). `lsregister -kill -r` does not clean these — explicit per-path `lsregister -u` does, which is what this script automates. Symptom in `log show`: `PlugInKit ... must have pid! Extension request will fail`.

## Known issues

**`auval` warns/fails on Class Data: `<type> == componentType`.**
`kAudioUnitProperty_ClassInfo` returns a dict that is missing the required `componentType`, `componentSubType`, `componentManufacturer`, `version`, `data` keys — see `IMPSYAudioUnit+State.swift` (the `fullState` implementation). Logic still loads the plugin, but `auval -v aumi impy 'CpM!'` finishes with `AU VALIDATION FAILED`, and Logic's Plug-in Manager may flag the plugin as "Failed Validation". Follow-up: have `fullState` getter include the four AU component descriptor keys around the existing key/value blob.
