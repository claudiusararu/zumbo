# Third-party notices

VesperEngine lifts implementation patterns and, in a few cases, near-verbatim
code from two MIT-licensed open source projects, read from `references/` at
the repository root. Their copyright lines are preserved here for the app's
Acknowledgements screen.

## OpenSuperWhisper

Copyright (c) 2024 OpenSuperWhisper

Used for: `AudioCapture.swift` (mic capture + format conversion, from
`AudioRecorder.swift`/`PCMRecording.swift`), `HotkeyMonitor.swift` (held-modifier
detection via a CGEvent tap, from `ModifierKeyMonitor.swift`), and the
microphone/accessibility/input-monitoring permission-check patterns (from
`PermissionsManager.swift`).

License: MIT. Full text at `references/OpenSuperWhisper/LICENSE`.

## OpenDictation

Copyright (c) 2025 Kenny

Used for: `TextInserter.swift` (Universal Paste via pasteboard + Cmd-V CGEvent,
from `TextInsertionService.swift`) and the FluidAudio `AsrManager` loading
pattern (from `ParakeetTranscriptionProvider.swift`/`ModelManager.swift`).

License: MIT. Full text at `references/OpenDictation/LICENSE`.

## FluidAudio

VesperEngine depends on FluidAudio 0.15.7 (https://github.com/FluidInference/FluidAudio)
via Swift Package Manager for the Parakeet TDT v3 model, CTC keyword spotting,
and vocabulary-boosting rescoring. See that project's own license for terms.
