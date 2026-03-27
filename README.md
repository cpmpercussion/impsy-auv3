# IMPSY AUv3

An AUv3 MIDI Processor plugin that runs the [IMPSY](https://github.com/cpmpercussion/impsy) intelligent musical instrument system on iOS and macOS. Load a TFLite MDRNN model and interact with it in call-and-response mode inside any AUv3 host (AUM, ApeMatrix, Logic Pro, etc.).

## What it does

- Listens to incoming MIDI messages and normalises them to the IMPSY model's input dimensions
- Runs in **call-and-response mode**: when you pause playing, the RNN generates MIDI responses; when you play, the RNN listens
- Each model dimension maps to a configurable MIDI message (Note On, CC, or Pitch Bend)
- Supports any `.tflite` IMPSY model (dim 2–16, layers 2–3)

## Requirements

- Xcode 16+
- iOS 17+ / macOS 14+
- [xcodegen](https://github.com/yonaskolb/XcodeGen) for project generation
- A TFLite IMPSY model (e.g. from `../impsy/models/`)

## Setup

### 1. Install xcodegen

```bash
brew install xcodegen
```

### 2. Add TensorFlow Lite Swift

The TFLite Swift package needs to be added to Xcode after generating the project. Two options:

**Option A — Swift Package Manager (recommended)**

After generating the project, open it in Xcode and add the package:
- File → Add Package Dependencies
- URL: `https://github.com/google-ai-edge/LiteRT`
- Product: `LiteRT`

Then update the import in `TFLiteRNN.swift` from `import TensorFlowLite` to `import LiteRT`.

**Option B — CocoaPods**

```ruby
# Podfile
target 'IMPSYExtension-iOS' do
  pod 'TensorFlowLiteSwift', '~> 2.14'
end
target 'IMPSYExtension-macOS' do
  pod 'TensorFlowLiteSwift', '~> 2.14'
end
```

```bash
pod install
```

### 3. Generate the Xcode project

```bash
cd impsy-auv3
xcodegen generate
```

### 4. Configure signing

Open `IMPSY-AUv3.xcodeproj` in Xcode and set your Development Team for all four targets:
- `IMPSYHost-iOS`
- `IMPSYHost-macOS`
- `IMPSYExtension-iOS`
- `IMPSYExtension-macOS`

### 5. Build and run

Select the `IMPSYHost-iOS` scheme and run on your iPad, or `IMPSYHost-macOS` for Mac. The AUv3 extension will be registered and available in hosts like AUM.

## Usage

1. Load a `.tflite` model using the **Load Model** button (picks from Files app)
2. Configure MIDI input/output mappings for each dimension
3. Adjust parameters (threshold, temperatures, timescale)
4. Route MIDI in and out in your AUv3 host

## IMPSY Model Files

IMPSY models are in `../impsy/models/`. Recommended starting model:
```
musicMDRNN-dim9-layers2-units64-mixtures5-scale10.tflite
```

## Parameters

| Parameter | Range | Default | Description |
|-----------|-------|---------|-------------|
| Threshold | 0.1–10s | 2.0s | Silence duration before RNN starts responding |
| Sigma Temp | 0.001–2.0 | 0.01 | Controls Gaussian sampling variance |
| Pi Temp | 0.1–5.0 | 1.5 | Controls mixture component diversity |
| Timescale | 0.1–4.0× | 1.0× | Multiplies predicted time deltas |

## Architecture

```
MIDI In → scheduleMIDIEventBlock → RingBuffer → InteractionEngine
                                                      ↓
                                               TFLiteRNN.generate()
                                                      ↓
                                               MDNSampler.sample()
                                                      ↓
                                         RingBuffer → internalRenderBlock
                                                      ↓
                                              midiOutputEventBlock → MIDI Out
```

See `PLAN.md` for full architectural details.
