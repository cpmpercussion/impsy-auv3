# App Store Connect listing — draft

Working draft of the text to enter into App Store Connect for IMPSY.
The two platforms share the identity fields (name, bundle ID, SKU) but get
distinct Description, Promotional text and Keywords — the host stories differ
(iOS music apps vs Mac DAWs, plus the Mac standalone-into-Ableton route).

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
| Privacy Policy URL | `https://charlesmartin.au/impsy-auv3/privacy.html` |
| Support URL | `https://charlesmartin.au/impsy-auv3/#support` |
| Marketing URL (optional) | `https://charlesmartin.au/impsy-auv3/` |
| Accessibility (not an ASC field; linked from the description) | `https://charlesmartin.au/impsy-auv3/accessibility.html` |

## Promotional text (170 chars, editable post-release without re-review)

### iOS

```
Jam with a neural network on iPad and iPhone. Play any MIDI controller into IMPSY in AUM, Cubasis or Logic, and it improvises responses back into your set.
```

### macOS

```
A neural-network MIDI partner for the Mac studio. Run it in Logic Pro and MainStage, or route any DAW (Ableton included) through its Core MIDI virtual ports.
```

## Description

### iOS

```
Jam with an AI MIDI partner on iPad and iPhone.

IMPSY listens to what you play and improvises musical responses. Load it as an AUv3 MIDI Processor in AUM, AudioBus, Cubasis or Logic Pro for iPad, play it from a USB or Bluetooth controller (or the on-screen faders), and route its output to any instrument app. IMPSY also runs on its own: it appears as Core MIDI virtual ports (IMPSY In / IMPSY Out) and connects directly to a plugged-in controller, so you can play it without a DAW.

How it works

IMPSY runs a Mixture Density Recurrent Neural Network (MDRNN) on-device. Every note, control change or pitch-bend you send becomes input to the model, which predicts what comes next, including the timing of the response. Shape the conversation with:

• Threshold: how long IMPSY waits between your input and its reply
• Sigma Temperature: randomness of pitch and control values
• Pi Temperature: randomness of which musical "idea" the model picks
• Timescale: speeds up or slows down the response
• MIDI Thru: passes your own playing through to the output alongside IMPSY's

Connect anything

• Map each model dimension to any MIDI message (notes, CCs or pitch-bend) on any channel, independently for input and output
• Connect a controller directly, or use the always-on IMPSY In / IMPSY Out virtual ports
• Import and export your mappings as TOML, compatible with the IMPSY Python toolkit

Custom models

IMPSY ships with a default 9-dimensional model trained for general musical interaction, but you can load any .tflite model trained with the open-source IMPSY research toolkit: synths, drum machines, lighting rigs, or anything that speaks MIDI.

Compatibility

• AUv3 MIDI Processor, no audio I/O
• Hosts in AUM, AudioBus, Cubasis and Logic Pro for iPad, or any other AUv3 host that supports midi processors.
• Also runs standalone with Core MIDI virtual ports and direct device connection
• Requires iOS 17
• MIDI stays on-device. No network, no telemetry
```

### macOS

```
Jam with an AI MIDI partner on your Mac.

IMPSY listens to what you play and improvises musical responses. Load it as an AUv3 MIDI Processor in Logic Pro or MainStage, or run the standalone app and plug your MIDI gear straight in. Because the standalone app appears as Core MIDI virtual ports (IMPSY In / IMPSY Out), you can route through IMPSY from any DAW, including ones that don't host AUv3 MIDI plug-ins such as Ableton Live, or play it without a DAW.

How it works

IMPSY runs a Mixture Density Recurrent Neural Network (MDRNN) on-device. Every note, control change or pitch-bend you send becomes input to the model, which predicts what comes next, including the timing of the response. Shape the conversation with:

• Threshold: how long IMPSY waits between your input and its reply
• Sigma Temperature: randomness of pitch and control values
• Pi Temperature: randomness of which musical "idea" the model picks
• Timescale: speeds up or slows down the response
• MIDI Thru: passes your own playing through to the output alongside IMPSY's

Connect anything

• Map each model dimension to any MIDI message (notes, CCs or pitch-bend) on any channel, independently for input and output
• Connect hardware or IAC MIDI devices directly, or use the always-on IMPSY In / IMPSY Out virtual ports
• Import and export your mappings as TOML, compatible with the IMPSY Python toolkit

Custom models

IMPSY ships with a default 9-dimensional model trained for general musical interaction, but you can load any .tflite model trained with the open-source IMPSY research toolkit: synths, drum machines, lighting rigs, or anything that speaks MIDI.

Compatibility

• AUv3 MIDI Processor, no audio I/O
• Hosts in Logic Pro and MainStage
• Standalone app with Core MIDI virtual ports works alongside any DAW, including Ableton Live; connect hardware or IAC MIDI devices directly
• Requires macOS 14 on an Apple Silicon Mac
• MIDI stays on-device. No network, no telemetry
```

## Keywords (100-char limit, no spaces after commas)

### iOS

```
AUv3,MIDI,AI,improvisation,generative,music,MDRNN,AUM,AudioBus,Cubasis,synth,iPad,plugin
```

### macOS

```
AUv3,MIDI,AI,improvisation,generative,music,MDRNN,Ableton,Logic,MainStage,synth,standalone,IAC
```

## What's New in This Version (170 chars, per build)

```
First release. AUv3 MIDI plug-in or standalone with Core MIDI virtual ports and direct device connections. Bundled neural model; load your own IMPSY models via Files.
```

## macOS submission notes

The macOS host uses `com.apple.security.temporary-exception.audio-unit-host` so the bundled extension can be previewed in the container window. Justification text for the App Review form:

> This app is an AUv3 plug-in container. The temporary-exception entitlement is used so the bundled AUv3 extension can be previewed in the container window for verification — no third-party Audio Units are loaded.

## Screenshots — required sizes

Generated by `scripts/capture-screenshots.sh`, light + dark, three screens each (Dashboard / Settings / Mapping). Stored in `appstore-screenshots/`.

| Device | Resolution | Status |
|---|---|---|
| iPhone 6.9" (16/17 Pro Max) | 1320×2868 | ✓ `appstore-screenshots/iphone-6.9/` (light + dark, mocked 9:41 status bar) |
| iPhone 6.5" | 1284×2778 | ✓ `appstore-screenshots/iphone-6.5/` — App Store Connect's iPhone slot here only accepts 6.5" sizes (1242×2688 or 1284×2778), so upload these for iPhone |
| iPad 13" (Pro M4/M5) | 2064×2752 | ✓ `appstore-screenshots/ipad-13/` (light + dark) |
| Mac | 2880×1800 (16:10) | ✓ `appstore-screenshots/macos/` — one trio mockup per appearance (all three screens) |

Plain macOS window screenshots used on the marketing site live in `docs/images/screens/`. App icon 1024×1024 lives in `Resources/AppIcon/`.

## Outstanding pre-submission checklist

- [x] Privacy Policy URL — live at charlesmartin.au/impsy-auv3/privacy.html (GitHub Pages)
- [x] Support URL — live at charlesmartin.au/impsy-auv3/#support
- [x] Register App IDs at developer.apple.com (unified, both bundle IDs)
- [x] Capture screenshots at each required size — see `appstore-screenshots/`
- [ ] Create the App record at appstoreconnect.apple.com (one record, both platforms)
- [x] Builds — uploaded automatically by Xcode Cloud (ci_scripts/ci_post_clone.sh builds the TFLite xcframework first); use the Xcode Cloud build in App Store Connect rather than a manual Organizer upload
- [ ] Resolve the `auval` Class Data note if it still flags (fixed in code; re-verify pre-submission)
- [ ] Justify the temporary-exception entitlement on macOS submission (text above)
