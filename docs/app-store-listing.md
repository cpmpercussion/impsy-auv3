# App Store Connect listing — draft

Working draft of the text to enter into App Store Connect for IMPSY.
The iOS and macOS app records share this text.

## Identity

| Field | Value |
|---|---|
| App name | `IMPSY — Intelligent MIDI` |
| Subtitle (30 chars) | `AI MIDI partner — AUv3 plugin` |
| Primary category | Music |
| Secondary category | Entertainment _(alt: Utilities)_ |
| Age rating | 4+ |
| Copyright | `© 2026 Charles Patrick Martin` |
| Bundle ID (host) | `au.charlesmartin.impsy` |
| Bundle ID (extension) | `au.charlesmartin.impsy.IMPSYExtension` |
| SKU | `impsy` |

One App Store Connect app record, both platforms (iOS + macOS) selected in the New App dialog. Each platform gets its own version, screenshots, and per-platform fields, but they share the name, bundle ID, and SKU.

## URLs

| Field | Value |
|---|---|
| Privacy Policy URL | _TODO — Charles to fill in_ |
| Support URL | _TODO — Charles to fill in_ |
| Marketing URL (optional) | _TODO — optional_ |

## Promotional text (170 chars, editable post-release without re-review)

```
A live duet between you and a neural network. Send MIDI from any keyboard, get back improvised musical responses — straight into your DAW.
```

## Description

```
Jam with an AI MIDI partner.

IMPSY listens to what you play and improvises musical responses in your DAW. Load it as an AUv3 MIDI Processor in Logic Pro, MainStage, AUM, AudioBus or Cubasis, send it MIDI from any keyboard or controller, and route its output to any instrument plug-in. The result is a live duet between you and a neural network trained on musical performances.

How it works

IMPSY runs a Mixture Density Recurrent Neural Network (MDRNN) on-device. Every note, control change or pitch-bend you send becomes input to the model, which predicts what should happen next — including the timing of the response. Four controls shape the conversation:

• Threshold — how long IMPSY waits between your input and its reply
• Sigma Temperature — randomness of pitch / control values
• Pi Temperature — randomness of which musical "idea" the model chooses
• Timescale — speeds up or slows down the response

Custom models

IMPSY ships with a default 9-dimensional model trained for general musical interaction, but you can load any .tflite model trained with the IMPSY research toolkit. Map each model dimension to any MIDI message — notes, CCs, pitch-bend — and use IMPSY with synths, drum machines, lighting rigs, or anything that speaks MIDI.

Compatibility

• AUv3 MIDI Processor — no audio I/O
• Developed and tested in Logic Pro; MainStage, AUM, AudioBus and Cubasis also host AUv3 MIDI Processor (aumi) plugins
• Requires iOS 17 or macOS 14
• MIDI stays on-device — no network, no telemetry

Credits

IMPSY is research software from Charles Patrick Martin (ANU School of Computing). The underlying IMPSY framework is open source at github.com/cpmpercussion/impsy.
```

## Keywords (100-char limit, no spaces after commas)

```
AUv3,MIDI,AI,neural,network,improvisation,generative,music,MDRNN,IMPSY,AUM,Logic,MainStage,plugin
```
89 characters used.

## What's New in This Version (170 chars, per build)

```
First release. Includes a bundled neural-network model trained for general musical interaction; load your own IMPSY models via Files.
```

## macOS submission notes

The macOS host uses `com.apple.security.temporary-exception.audio-unit-host` so the bundled extension can be previewed in the container window. Justification text for the App Review form:

> This app is an AUv3 plug-in container. The temporary-exception entitlement is used so the bundled AUv3 extension can be previewed in the container window for verification — no third-party Audio Units are loaded.

## Screenshots — required sizes

| Device | Resolution | Status |
|---|---|---|
| iPhone 6.7" (15/16 Pro Max) | 1290×2796 | TODO |
| iPhone 6.5" (XS Max / 11 Pro Max) | 1242×2688 _(optional if 6.7 supplied)_ | TODO |
| iPad Pro 12.9" 6th gen | 2048×2732 | TODO |
| iPad Pro 13" M4 (recommended) | 2064×2752 | TODO |
| Mac | 1280×800 minimum | TODO |

App icon 1024×1024 already lives in `Resources/AppIcon/`.

## Outstanding pre-submission checklist

- [ ] Privacy Policy URL — host on charlesmartin.au or repo Pages
- [ ] Support URL — host on charlesmartin.au or link to repo issues
- [x] Register App IDs at developer.apple.com (unified, both bundle IDs)
- [ ] Create the App record at appstoreconnect.apple.com (one record, both platforms)
- [ ] Capture screenshots at each required size
- [ ] Upload archives via Xcode Organizer
- [ ] Justify the temporary-exception entitlement on macOS submission (text above)
