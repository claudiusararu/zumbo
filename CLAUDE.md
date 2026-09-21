# Zumbo

Native macOS dictation app. Local Parakeet TDT v3 via FluidAudio, notch UI, developer vocabulary, one-time price, sold direct as a notarized app.

Public repository (GPL-3.0). Paths beginning with ../ exist only on the maintainer's machine; skip those steps elsewhere. Spec and decisions: ../dictation-spike/NOTES.md (read first). Measurements: ../dictation-spike/SPIKE_RESULTS.md and ../dictation-spike/recordings/TUNING_RESULTS.md. Supaste reference screenshots: ../dictation-spike/reference/.

## Rules for every agent and session
- Commits are authored by the repo's git identity only. Never add Co-Authored-By, Claude-Session or "Generated with" trailers.
- Plain dashes only, never em-dashes, in code, comments, copy and docs.
- Run every build, test and model download through ../hooppaper/scripts/safe-run.sh (memory cap). One transcription process at a time.
- references/ holds MIT clones (OpenSuperWhisper, OpenDictation) for reading and lifting code. Keep their copyright lines for the Acknowledgements screen. boring.notch was removed because it is GPL: never copy from it, write the notch shape ourselves.
- Xcode project is generated from project.yml with XcodeGen (installed). Never hand-edit the .xcodeproj; edit project.yml and rerun xcodegen.
- FluidAudio pinned exactly at 0.15.7. Boosting = post-hoc CTC rescoring pass with minSimilarity 0.75 (see seeds/spike-fluidaudio-recipe.swift for the working API).
- No dock icon (LSUIElement). The notch panel is a nonactivating NSPanel and must never take focus.
- Bundle id: com.claudiusararu.zumbo (domain is decided: zumbo.app; must not change after first public build).
- App renamed from Vesper to Zumbo 2026-09-20 (see ../dictation-spike/NOTES.md "RENAME"). Scheme/target: Zumbo. Built app: build/DerivedData/Build/Products/Release/Zumbo.app, installed at /Applications/Zumbo.app. CLI product: zumbo-cli (Engine/Sources/zumbo-cli). Swift module name stays VesperEngine (folder Engine/, not renamed - would touch every import for no benefit). Repo folder stays `vesper`.
- Minimum macOS 14.
