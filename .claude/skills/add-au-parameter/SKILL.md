---
name: add-au-parameter
description: Checklist for adding a new automatable AU parameter to IMPSY AUv3 (parameter tree, engine wiring, fullState, view model).
---

# Add a new AU parameter

1. Add case to `ParameterAddress` enum in `IMPSYParameters.swift`
2. Add defaults/ranges to `ParameterDefaults`/`ParameterRanges`
3. Add `createParameter` call in `IMPSYAudioUnit+Parameters.swift`
4. Handle in `implementorValueObserver` and `implementorValueProvider`
5. Add property to `InteractionEngine` and wire it up
6. Add `StateKey` and handle in `IMPSYAudioUnit+State.swift`
7. Add `@Published` property and sync in `IMPSYViewModel`

Then update the AU Parameters table in `CLAUDE.md`.
