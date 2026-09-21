# Zumbo

Dictation for macOS that runs on your own Mac. Press a shortcut, talk, and the text lands where your cursor is, in any app, in about a fifth of a second. No account, no server, nothing uploaded.

Site, download and license: https://zumbo.app

## What is in this repository

The complete app: the notch interface, the dictation pipeline, the rules that clean up speech (fillers, repeats, false starts, numbers, currency, spoken punctuation), vocabulary boosting, the Teach loop, Notes with reminders, Meeting mode with speaker labels, onboarding, settings, licensing client, and the update client. Also the 22 vocabulary packs in `seeds/packs`.

Not in the repository: the speech model. The app uses NVIDIA Parakeet TDT v3 through [FluidAudio](https://github.com/FluidInference/FluidAudio). A build from source downloads the model from Hugging Face on first launch, about 570 MB, once. The paid build from zumbo.app ships with the model inside the DMG so it works with the network off from the first second.

## Building from source

Requirements: macOS 14 or newer, Xcode 16 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
cp project.example.yml project.yml
xcodegen generate
xcodebuild -scheme Zumbo -configuration Release -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Release/Zumbo.app
```

`project.yml` is gitignored. The example carries placeholders for the signing team, bundle identifier, update feed and Sparkle key: fill in your own or leave them, an unsigned local build works without them. Zumbo needs Microphone and Accessibility permissions; macOS ties Accessibility to the signature and path, so re-grant it after changing either.

Engine tests:

```
cd Engine && swift test
```

## Paid build versus source build

Same code. The paid build adds: Developer ID signing and notarization, Sparkle updates, the speech model bundled in the DMG, and the speaker labels add-on served from our bucket. Every build starts a 3 day trial and asks for a license key after that. Keys are sold once, per Mac count, at https://zumbo.app/buy. Buying is how this project is funded.

## Using another model

The engine is built around Parakeet through FluidAudio: `Engine/Sources/VesperEngine/Transcriber.swift` loads it, and vocabulary boosting is Parakeet's CTC rescoring pass. Another model means replacing that file's loading and transcription calls, and boosting will not apply to it. There is no model picker in the app today.

## Layout

- `Sources/` the app: `App`, `Dictation`, `History`, `Notch`, `Onboarding`
- `Engine/` a Swift package with the pipeline, rules, dictionary, licensing core and the `zumbo-cli` tool
- `seeds/` vocabulary packs and the starter dictionary builder
- `design/` icon and logo sources
- `docs/ARCHITECTURE.md` how the pieces fit

## Contributing

Issues and pull requests are welcome, vocabulary packs most of all: each pack is one JSON file in `seeds/packs` with a term, its spoken aliases and an optional similarity threshold. Keep plain dashes in copy and comments, never em-dashes. Do not add generated trailers to commit messages.

## License

GPL-3.0, see `LICENSE`. Third party notices in `NOTICES.md`. The Zumbo name, icon and logo are not covered by the license.
