# VesperEngine

The speech pipeline for Zumbo, as a standalone local Swift package. No UI
code lives here - the app shell (built in parallel, elsewhere in this repo)
drives this package through `DictationSession` / the `DictationEngine`
protocol.

## Modules

| File | What it does |
|---|---|
| `AudioCapture.swift` | `AVAudioEngine` mic tap converted to 16 kHz mono Float32. `start()`/`stop()` (returns the captured samples), `levels: AsyncStream<Float>` (~30 Hz smoothed RMS, 0...1), `MicrophonePermission` check/request. |
| `Transcriber.swift` | Loads Parakeet TDT v3 via FluidAudio 0.15.7 (`AsrModels.downloadAndLoad`, `AsrManager`), keeps it warm, `transcribe(samples:alwaysIncludeTerms:)`. Vocabulary boosting is the FluidAudio CTC post-hoc rescoring pass (`enableBoosting(vocabularyPath:minSimilarity:)`), default `minSimilarity` 0.75 (the winning config from `dictation-spike/recordings/TUNING_RESULTS.md`). Every call first runs `CandidateFilter` over the full boosting vocabulary and only spots/rescores against the survivors - see "Boosting: pre-filter, then warm CTC" below. `modelLoadProgress: AsyncStream<Double>` reports real fractional download/compile progress from FluidAudio's own `progressHandler`, not an indeterminate placeholder. |
| `CandidateFilter.swift` | Pure-Swift, no-model pre-filter: scores every dictionary term's aliases against the plain transcript's word n-grams (1-4 words) with Jaro-Winkler plus a consonant-skeleton phonetic proxy, keeps the top `maxCandidates` (40) plus every `alwaysInclude` term. This is what makes boosting affordable at 1721 terms - see below. |
| `Replacer.swift` | `VocabTerm`/`VocabFile` (the `{"terms":[{"text":...,"aliases":[...],"pack":...}]}` shape) plus `Replacer`: deterministic alias-to-canonical replacement, longest alias first, word-boundary, with the `seeds/Replacement.swift` punctuated-canonical span guard (protects e.g. `package.json` from being re-mangled by an unrelated `json` alias). |
| `Rules.swift` | `RulesEngine`/`RulesConfig`: runs `Replacer` first, then the toggleable rule groups - `cleanSpeech` (fillers, repeats, false starts; on), `contractions` (gotta/wanna/kinda/gonna; **off**), `numbers` (word-to-digit, including compounds and decimals; on), `currency` ($/€/£/%; on), `spokenPunctuation` (`--flag`, `:`, `\n`, parens; on). |
| `Dictionary.swift` | `VesperDictionary` (not `Dictionary`, to avoid shadowing the standard library type): starter pack from the bundled `Resources/vocab-dev-starter.json`, `UserDictionaryStore` (JSON persistence at `~/Library/Application Support/Zumbo/dictionary.json`), and the merge into the plain vocabulary list `Transcriber`/`Replacer` consume. Every term carries a `pack` field (the `seeds/packs/*.json` file it came from); `UserDictionaryStore.enabledPacks` (default `nil` = every pack enabled) drops whole packs from the merge before boosting ever sees them. |
| `DevContext.swift` | `DevContextGate`: Auto/Always/Off topic gating. Score = ~150-word developer vocabulary hits + dictionary hits (weighted) + a decayed memory of the last 5 dictations, with the frontmost app (Terminal, iTerm, Xcode, VS Code, Cursor, Windsurf, Zed, ChatGPT) as a small tie-breaker bonus only. |
| `TextInserter.swift` | Pastes via the pasteboard + a Cmd-V `CGEvent`, restores the previous pasteboard contents 300 ms later (skipped if the clipboard changed again in the meantime). `TextInserter.isAccessibilityTrusted()` / `requestAccessibilityPermission()`. |
| `HotkeyMonitor.swift` | Hold-to-record hotkey, hybrid and automatic: a tap (press+release under `HotkeyMonitor.tapHoldThreshold`, 300 ms) toggles recording on, the next tap toggles it off; a press held past the threshold is push-to-talk and stops on release. `trigger: HotkeyTrigger` (`.modifier(.fn/.rightOption/.rightCommand)` or `.combo(HotkeyCombo)`) is a small `Codable` value type, persisted via `HotkeyTrigger.load(from:)`/`.save(to:)` on `UserDefaults`, and can be reassigned on a running monitor at any time - no restart needed. `InputMonitoringPermission` check/request. |
| `DictationSession.swift` (see "Boosting is warmed once" below) | Orchestrates capture -> stop -> transcribe -> `DevContextGate` decision -> (conditional) boosting -> `RulesEngine` -> `TextInserter`. Conforms to `DictationEngine` (`levels`, `start()`, `stop() -> String`) - the app declares the same protocol independently; the two are reconciled where both land in one target. |

## Boosting: pre-filter, then warm CTC

Full-dictionary boosting used to cost seconds per dictation: the CTC spotter
and rescorer's cost scales with vocabulary size, so running them against all
1721 starter terms on every dictation was the dominant cost end to end
(measured on a 5.7 s clip, Debug: spotter 738 ms + rescore 2544 ms at 1721
terms, vs 269 + 216 ms at 150, 234 + 56 ms at 40). The fix is
`CandidateFilter`, run inside `Transcriber.transcribe(samples:)` before the
spotter/rescorer ever see the vocabulary:

1. **`loadModel()`** warms Parakeet, then kicks off `prepareBoostingIfNeeded()`
   as a **background task** (it no longer blocks `loadModel()`'s return). That
   call still does the one expensive thing: `CustomVocabularyContext
   .loadWithCtcTokens` loads/compiles the CTC CoreML models and tokenizes
   every dictionary term. This cost is dominated by the CoreML model load, not
   by dictionary size - measured 0.7-4.6 s once the OS's disk cache is warm,
   up to ~10-15 s cold, the *same* whether the vocabulary is 40 terms or 1721
   (verified: a 40-term vocabulary measured 10.6 s cold, slower than the
   1721-term vocabulary measured warm moments later in the same process). It
   happens once per app launch and is not on the critical path for the first
   dictation, which just runs unboosted (`transcribe` already falls back to
   plain text whenever the spotter/rescorer/vocabulary aren't ready) until it
   completes.
2. **Every `transcribe(samples:alwaysIncludeTerms:)` call** runs
   `CandidateFilter.select` over the plain ASR transcript first: word n-grams
   (1-4 words) against every alias and the canonical text of every dictionary
   term, lowercase, scored by the larger of a Jaro-Winkler similarity and a
   consonant-skeleton comparison (a cheap phonetic proxy - strip vowels, so
   "colonel"/"kernel" share a skeleton), threshold ~0.5, capped at 40
   candidates plus every term in `alwaysIncludeTerms` (the caller's own
   dictionary entries, which must always be considered regardless of score).
   Pure Swift, no model, precomputed lowercase aliases/skeletons at
   `enableBoosting` time (`CandidateFilter.Index`) so the hot path never
   re-derives them.
3. The already-tokenized `vocabulary.terms` (from step 1) are filtered
   in-memory to the survivors - a plain `Array.filter`, no re-tokenization, no
   CTC model reload - and the spotter/rescorer run against that filtered
   `CustomVocabularyContext` instead of the full one. Only the lightweight
   `VocabularyRescorer` wrapper is rebuilt per call (it re-reads a small
   tokenizer JSON, not the CoreML models); the context-biasing weight (`cbw`)
   is cached from the *full* vocabulary's size at `enableBoosting` time and
   reused, not recomputed per call - FluidAudio's own size heuristics
   (`ContextBiasingConstants`) assume a small vocabulary is a deliberately
   curated one and relaxes its gates accordingly, which is wrong for a
   filtered *subset* of a large dictionary. In particular
   `VocabularyRescorer.Config.spotterRescueEnabled` is forced `false`: that
   pass only activates when the vocabulary it's handed has <= 10 terms (which
   `CandidateFilter`'s output often does for a short sentence) and is
   FluidAudio's own documented "dominant source of short-keyword
   over-firing" - leaving it on was measured to add 1 false insertion on the
   bench with no recall benefit.

One `transcribe` call still returns both readings - `plainText`
(pre-rescoring) and `text` (boosted) - plus per-stage timings (`asrMs`,
`filterMs`, `spotterMs`, `rescoreMs`), so the dev-context gate chooses between
them without a second pass over the audio.

### Measured, Debug vs Release (6.6 s clip, `zumbo-cli transcribe`)

Stage ms with the pre-filter always on, by *underlying dictionary size*
(the filter narrows all three down to a similar handful of real candidates
for this clip, which is the point - total time stops depending on how big the
dictionary is):

| Terms | Debug asr/filter/spotter/rescore/total | Release asr/filter/spotter/rescore/total |
|---|---|---|
| 40 | 90 / 11 / 241 / 81 / **424 ms** | 75 / 0 / 98 / 32 / **207 ms** |
| 150 | 87 / 47 / 259 / 86 / **482 ms** | 71 / 1 / 97 / 32 / **202 ms** |
| 1721 (full starter pack) | 89 / 611 / 251 / 104 / **1057 ms** | 74 / 14 / 96 / 34 / **219 ms** |

Release, full dictionary, is comfortably under the 400 ms (key-release to
pasted text, 5 s clip) target. `filterMs` itself runs a little over the 10 ms
design budget for `CandidateFilter` alone at 1721 terms in Release (~10-14 ms
measured) - `jaroWinkler` uses `UInt64` bitmasks instead of heap-allocated
`[Bool]` arrays to keep this down, since the pre-filter runs O(vocabulary
size) times per dictation - but it is a small fraction of the 400 ms budget
either way, so it was left as-is rather than chasing the last few ms (e.g. by
switching to raw ASCII bytes, which would risk the `ro-tech` pack's
diacritics). Debug is 5-25x slower across every stage, same as always for
tight Swift loops and unoptimized CoreML - use Release for anything
timing-sensitive.

The one-time `enableBoosting` setup cost is *not* size-dependent (see above):
40 terms measured 10.6 s cold, 150 and 1721 terms measured 180-745 ms warm
moments later in the same process, all in the same run.

### Bench with the pre-filter (`manifest_human.json`, 30 items, full 1721-term dictionary, Release)

```
items: 30
term recall: 63/70 = 90.0%
term precision: 63/77 = 81.8% (14 false insertions)
median ms: 189
median stage ms: asr 62, filter 10, spotter 93, rescore 24
```

This is **not worse** than the pre-filter-off baseline measured on the exact
same code otherwise (`git stash` A/B on this dictionary/manifest): median
3651 ms, 63/70 recall, 63/78 precision (15 false insertions) - i.e. the
pre-filter earns its ~19x speedup (3651 ms -> 189 ms median) for identical
recall and slightly better precision (disabling `spotterRescueEnabled` costs
nothing and fixes one of the false insertions). What it does **not** do is
close a pre-existing gap against the ~94.3%/97.1% this manifest scored against
the original 656-term dictionary (`TUNING_RESULTS.md`): the starter pack has
grown to 1721 terms since then across many more packs (finance, legal,
medical, ro-tech, etc.), and several of those terms are close enough in
sound to this manifest's spoken sentences to win a false replacement (e.g.
"the app" -> "GAAP", "the config" -> "tsconfig", "target" -> a
Romanian-suffixed ro-tech term) independent of any candidate filtering -
confirmed because the un-filtered baseline has the exact same 90.0% recall
profile on the current dictionary. Retuning `minSimilarity`/per-term overrides
against the larger vocabulary is a separate exercise from this one (which was
scoped to speed, not to re-tuning accuracy) and is tracked as follow-up, not
done here.

`DictationSession.maxBoostTerms` still exists (0 = no cap, the default) as a
hard ceiling independent of the per-dictation candidate filter; with
`CandidateFilter` in place it is no longer the practical lever for keeping
boosting fast, since the filter already bounds the spotter/rescorer's input.

Per-term `minSimilarity` in the dictionary JSON is carried through
`DictionaryTerm` -> `VocabTerm` -> the vocabulary file FluidAudio reads (146 of
the starter terms set it). It was being dropped before, which is why a common
word like "Jest" could fire at the global 0.75 floor.

### Packs and `enabledPacks`

Every term in `Resources/vocab-dev-starter.json` now carries a `pack` field -
the `seeds/packs/*.json` file name it came from (e.g. `"ai"`, `"devtools"`,
`"ro-tech"`) - produced by `seeds/build-starter.py` and carried through
`DictionaryTerm.pack` -> `VocabTerm.pack`. A user-taught term (added via
"Teach") has `pack == nil` and is never affected by pack filtering.
`UserDictionaryStore.enabledPacks: Set<String>?` (default `nil` = every pack
enabled - there is no onboarding pack picker yet) drops starter terms whose
pack isn't in the set before they ever reach `mergedVocabulary()`, so
disabled-pack terms never enter the candidate pool, never get boosted, and
never get replaced by `Replacer`. The app will set this from an onboarding
pack picker later; until then every pack ships on.

## Language hint

`Transcriber.transcribe(language:)` (or `languageCode:` for callers outside
`VesperEngine`, like `zumbo-cli`) passes FluidAudio's `Language?` through to
`AsrManager.transcribe`, which - only for the v3 joint decoder we use -
filters the decoder's top-K token candidates to the hint's Unicode script
(Latin/Cyrillic/Greek) via FluidAudio's `TokenLanguageFilter`. This is the
fix for "Testing testing testing" transcribing as Cyrillic: Parakeet TDT v3
is multilingual and auto-detects per utterance with no hint, and short or
ambiguous audio occasionally auto-detects the wrong script. The hint is
never passed into the boosting/rescoring pass (the CTC spotter and
`VocabularyRescorer`) - FluidAudio's own comments on the joint decoder warn
that would either be a no-op (no right-language top-K candidate exists) or
silently corrupt the boosted text, since that pass matches text against the
vocabulary, not against a script. `nil` = auto, Parakeet's default.
`AppSettings.language`/`.multilingual` in the app map to this: multilingual
on always sends `nil` regardless of the chosen main language.

Bench (`manifest_human.json`, 30 English recordings, dev preset, Release,
`zumbo-cli bench`), hint off vs. `--language en`:

| | recall | precision | median ms |
|---|---|---|---|
| no hint (auto) | 64/70 = 91.4% | 64/69 = 92.8% (5 false insertions) | 193 |
| `--language en` | 64/70 = 91.4% | 64/69 = 92.8% (5 false insertions) | 195 |

Identical recall/precision, latency within noise - the hint costs nothing
on English audio, which is what the default `"en"` main language should do
for the English-only launch.

## Fn/Globe key note

If the hotkey trigger is `.modifier(.fn)`, macOS's own **System Settings >
Keyboard > Press Globe key** must be set to **"Do Nothing"**. Otherwise the
system's dictation/emoji-picker popup intercepts the same keypress and fights
this app's own hotkey. Surface this in onboarding, not just here.

## Building and running

Every build/test/model-download must go through the memory-capped wrapper:

```
../hooppaper/scripts/safe-run.sh -m 8192 -t 590 -- swift build
../hooppaper/scripts/safe-run.sh -m 8192 -t 590 -- swift test
../hooppaper/scripts/safe-run.sh -m 12288 -t 590 -- swift run zumbo-cli transcribe <wav>
```

Models are expected to already be cached at
`~/Library/Application Support/FluidAudio/Models/` (about 1 GB); no download
should be needed on this machine.

### `zumbo-cli`

```
zumbo-cli transcribe <wav> [--no-boost] [--vocab file] [--rules off]
zumbo-cli bench <manifest.json>
```

- `transcribe` prints the raw transcript, the boosted transcript (unless
  `--no-boost`), and the final text after `RulesEngine` (with the default
  starter-pack vocabulary and default `RulesConfig`, unless overridden), plus
  model-load and transcription timings.
- `--vocab file` boosts with that vocabulary JSON instead of the starter pack.
- `--rules off` runs `RulesConfig.allOff` (dictionary replacement still runs;
  everything else is verbatim).
- `bench <manifest.json>` reuses the `dictation-spike/recordings/manifest_human.json`
  shape (`items[].wav/expected/terms`), boosts with the starter-pack
  vocabulary at `minSimilarity 0.75`, and reports term recall/precision plus
  median transcription time. One `Transcriber` instance is warmed up once and
  reused sequentially for the whole run (one transcription process at a time).

  Term recall = correct expected-term occurrences / total expected-term
  occurrences. Term precision = correct / (correct + false insertions), where
  a false insertion is any *other* vocabulary term appearing in the output
  that isn't in that item's expected text. This mirrors the methodology
  described in `TUNING_RESULTS.md`, though the exact scoring script used for
  that file was not checked into the repo, so is reimplemented here rather
  than reused verbatim.

### Bench numbers

Historical: measured 94.3% recall / 97.1% precision / 2 false insertions / 190
ms median against the original 656-term dictionary, matching
`dictation-spike/recordings/TUNING_RESULTS.md`'s best-config row (183 ms
median there - within run-to-run noise on the same machine). The starter pack
has since grown to 1721 terms across many more packs; see "Bench with the
pre-filter" above for the current numbers against today's dictionary
(90.0% recall / 81.8% precision, unchanged from the pre-filter-off baseline on
the same dictionary - the gap versus 94.3%/97.1% predates and is independent
of the pre-filter work, see that section for detail) and for `median stage
ms` (`asr`/`filter`/`spotter`/`rescore`), which `bench` now reports alongside
`median ms`.

## Tests

`swift test` runs 66 cases with no microphone dependency:

- `RulesTests.swift` (43 cases), including the numbers-rule guards: a lone
  number word only becomes a digit in a chain ("one hundred", "one point
  five"), after a currency marker or an index noun ("version two", "step
  one"), or in front of a measure or plural count noun ("two seconds", "two
  dogs"). "one" never converts alone, so "a custom one", "one day" and "one of
  them" stay words. Other cases: every rule group, including the exact
  sentences from NOTES.md ("I'd like them to I'd like it to be uh on by
  default", "Two hundred bucks versus two hundred Euros", "dash dash force",
  "localhost colon 3000", "type sense" with a `Typesense` dictionary entry).
- `DictionaryTests.swift` (8 cases): starter pack loading, user/starter merge
  and override semantics, disabled-term filtering, JSON round-trip,
  `UserDictionaryStore` add/remove/persist.
- `DevContextTests.swift` (9 cases): Auto/Always/Off modes, dev-word and
  dictionary-hit scoring, memory stickiness and decay, frontmost-app
  tie-breaker (never a sole decider).
- `CandidateFilterTests.swift` (6 cases): a plausible alias is selected, an
  exact alias always wins, `alwaysInclude` survives regardless of score, an
  empty transcript still keeps `alwaysInclude` terms, the `maxCandidates` cap
  holds under an adversarial all-plausible vocabulary, `jaroWinkler` identity/
  empty-string/phonetic-alias cases. Deliberately does not assert "an
  unrelated transcript selects nothing" - see the file's header comment on why
  that isn't this layer's job.

## Permissions required

- **Microphone** - `AudioCapture` (`MicrophonePermission`).
- **Accessibility** - `TextInserter`'s Cmd-V simulation
  (`TextInserter.isAccessibilityTrusted()`/`requestAccessibilityPermission()`).
  Without it, `insert(_:)` still copies to the clipboard and returns
  `.copiedOnly` instead of pasting.
- **Input Monitoring** - `HotkeyMonitor`'s CGEvent tap
  (`InputMonitoringPermission.isAuthorized()`/`.request()`).

## Meeting mode

Live chunked transcription plus speaker labels for long-form meeting
recordings, added 2026-09-18. Three pure/orchestration pieces:

- `MeetingChunker` (`Sources/VesperEngine/MeetingChunker.swift`) - splits a
  continuous stream into transcribable chunks from a sequence of VAD
  speech-start/speech-end sample indices: closes on ~0.7 s of silence once a
  chunk holds >= 2 s of speech, force-closes at 30 s regardless. Pure,
  model-free, no audio - see `MeetingChunkerTests.swift` (7 tests).
- `SpeakerAligner` (`Sources/VesperEngine/SpeakerAligner.swift`) - aligns a
  chunk's word timings (`WordTiming`, chunk-relative) against the diarizer's
  meeting-relative `DiarizerSegment`s to produce labeled paragraphs, merging
  consecutive same-speaker words into one paragraph. Matches by a word's
  midpoint (handles a word straddling a segment boundary), prefers a
  finalized segment, falls back to tentative, then to the nearest segment
  edge within 0.6 s (covers the diarizer's ~80 ms frame rate and its confirm
  latency at a chunk's first words - without this fallback, real audio showed
  a stray unlabeled word or two ahead of every speaker change). `SpeakerNumbering`
  assigns stable "Speaker N" labels in order of first appearance and never
  reassigns. Pure, model-free (plain FluidAudio value types) - see
  `SpeakerAlignerTests.swift` (8 tests).
- `MeetingSession` (`Sources/VesperEngine/MeetingSession.swift`) - the
  orchestrator: feeds mic audio (via `AudioCapture`'s new `streaming: true`
  mode, see below) to `MeetingChunker` through FluidAudio's Silero VAD
  streaming API (`VadManager.processStreamingChunk`) and, in parallel, to a
  `SortformerDiarizer` (`addAudio`/`process`); when a chunk closes it is
  transcribed serially through the same `Transcriber` instance a plain
  dictation uses (one transcription process at a time - the actor already
  serializes this), then `SpeakerAligner` labels it and a `RulesEngine` pass
  formats the text. Emits `MeetingParagraphUpdate`s over an `AsyncStream`.
  Pause drops incoming audio before it reaches the pipeline (mic tap keeps
  running so resume is instant) without touching the diarizer's session, so
  speaker numbers stay stable across a paused gap; resume forces the next
  paragraph to start fresh rather than merging into the pre-pause text.

`AudioCapture.start(streaming: true)` is the memory-bounded live path: it
delivers samples through a new `sampleBatches: AsyncStream<[Float]>` instead
of appending them to the array `stop()` returns, so a long meeting never
grows an unbounded in-memory buffer (`MeetingSession` keeps its own small
per-chunk buffer, trimmed after every closed chunk). Plain dictation and
notes are unaffected: `start()` with no argument is unchanged.

`SpeakerModelManager` (`Sources/VesperEngine/SpeakerModelManager.swift`)
wraps `AddOnStore` (see "Add-on store" below) for the `speaker-labels`
add-on and hands out a `SortformerDiarizer` the same way `Transcriber
.warmUp()` hands out Parakeet: idempotent install, a `statusUpdates` stream
for UI progress. **Measured add-on size: 234 MB unzipped, ~221 MB zipped**
(`~/Library/Application Support/Zumbo/AddOns/speaker-labels/v1/v3/fp16/Sortformer_v2.1.mlmodelc`).
Since 2026-09-18 nothing downloads the add-on automatically: if it is not
installed or the "Label speakers" switch is off when a meeting starts, the
meeting still starts recording immediately and runs the whole way through
without labels (`MeetingLabelAvailability.unavailable`) - mid-meeting
upgrade once an install finishes mid-recording is not implemented (see "What
is not done"): the diarizer's internal frame clock only makes sense if it
received audio from the meeting's first sample, so a clean mid-meeting join
would need a second clock-alignment step that wasn't worth the added risk in
this batch.

### Real-audio verification (`zumbo-cli meeting <wav> [--no-labels]`)

Feeds a WAV through the exact pipeline above in 100 ms batches (simulating
`AVAudioEngine`'s tap), printing each paragraph as it closes plus a
latency/turn summary - added specifically so this exercises `MeetingSession`
itself, not a re-implementation of it.

Test file: six turns synthesized with `say -v Samantha` / `say -v Daniel`
(alternating, 5-10 s each), converted to 16 kHz mono WAV with `afconvert`,
concatenated with ~1.4 s of low-level dithered "room tone" between turns
(**pure digital-zero silence does not read as silence to Silero VAD** -
its probability floor on true zero samples never dropped below ~0.26 in
testing, so no `speechEnd` ever fired and the chunker only ever force-closed
at the 30 s cap; a small amount of noise, closer to a real room, fixed this
immediately - worth knowing if a future test WAV is synthesized fully
silent). 46.3 s of audio, 123 words.

Result: **7 chunks** (six ~1.4 s pauses split six conversational turns into
seven; the trailing 1.2 s sliver merged into the prior speaker's paragraph),
**two speakers came out as two stable "Speaker 1"/"Speaker 2" labels for the
entire 46 s file**, correctly matching every turn to the right voice, no
mislabels. Per-chunk transcription latency: 66-113 ms (chunk sizes 1.2-9.0 s
of audio). Total wall time for the whole file (warm models): **2.9 s**. Cold
(first run after the add-on is installed, including 3.5 s Silero VAD
download + 12.7 s Parakeet compile): ~30 s one-time cost, never repeated;
the speaker-labels add-on install itself (11.9 s at 20.2 MB/s, see "Add-on
store" below) only happens once, driven by the user, not by a meeting start.

### What is not done here

- Mid-meeting upgrade from unavailable to active labels once a background
  model download finishes (see above) - the whole meeting runs with or
  without labels, decided once at start.
- The diarizer's own tentative-vs-finalized reconciliation at
  `finalizeSession()` is called but this batch does not re-emit already-sent
  paragraphs if a tentative label the meeting note already shows turns out to
  differ once finalized - in testing this never happened (labels were stable
  well before finalization), but it is a real, undemonstrated gap for a
  meeting where the diarizer changes its mind late.
- No system-audio capture path (NOTES.md's meeting mode "Level 2", Teams/Zoom
  via ScreenCaptureKit) - mic-only, as specified.

## Add-on store

Added 2026-09-18: the speaker-labels model is downloaded from our own
Cloudflare R2 bucket (`vesper-models`), never from Hugging Face at runtime -
see docs/ARCHITECTURE.md's "Add-on store" section for the full design
(`AddOnStore`, `AddOnManifest`, `AddOnInstalledMarker`, the
`MLModel(contentsOf:)` vs. `initialize(mainModelPath:)` decision).

### Packaging and uploading a new add-on version

1. Make sure the model files are on disk locally (for speaker labels:
   FluidAudio's own HuggingFace-backed `SortformerModels.loadFromHuggingFace`
   downloads them once into `~/Library/Application Support/FluidAudio/Models/
   sortformer` - a one-time step to get the source files, never done by the
   shipped app).
2. Run the packaging script from the repo root:
   ```
   scripts/package-addon.sh
   ```
   It zips the source directory deterministically (`ditto -c -k --norsrc
   --noextattr`, `.DS_Store` stripped first), writes
   `addon-build/speaker-labels/v1/manifest.json` (id, version, displayVersion,
   zipSizeBytes, installedSizeBytes, sha256, minAppBuild, rootPath) and
   `addon-build/catalog.json` (which version is current for each add-on id).
   Pass a source/output directory as `$1`/`$2` to package a different add-on
   or a new version (bump `ADDON_VERSION` and `ROOT_PATH` at the top of the
   script first).
3. Upload the three files with wrangler (needs an R2-enabled Cloudflare
   account logged in; the moonlisted checkout at
   `~/htdocs/PERSONALE/moonlisted` already is):
   ```
   cd ~/htdocs/PERSONALE/moonlisted
   ./node_modules/.bin/wrangler r2 object put vesper-models/speaker-labels/v1/speaker-labels-v1.zip \
     --file ~/htdocs/PERSONALE/vesper/addon-build/speaker-labels/v1/speaker-labels-v1.zip \
     --content-type application/zip --remote
   ./node_modules/.bin/wrangler r2 object put vesper-models/speaker-labels/v1/manifest.json \
     --file ~/htdocs/PERSONALE/vesper/addon-build/speaker-labels/v1/manifest.json \
     --content-type application/json --remote
   ./node_modules/.bin/wrangler r2 object put vesper-models/catalog.json \
     --file ~/htdocs/PERSONALE/vesper/addon-build/catalog.json \
     --content-type application/json --remote
   ```
   Never delete an existing object - old app builds may still be pointed at
   an older manifest/zip pair.
4. Verify with `curl -sI <baseURL>/speaker-labels/v1/speaker-labels-v1.zip`
   and confirm `Content-Length` matches the manifest's `zipSizeBytes`.
5. Real end-to-end check: `rm -rf ~/Library/Application\ Support/Zumbo/AddOns`
   then `swift run zumbo-cli addon install speaker-labels` (prints download
   progress and a final MB/s figure), then `swift run zumbo-cli meeting
   <wav>` and confirm `label availability: active`.

**Measured 2026-09-18**: 220,716,143 bytes (210 MB) zipped, 240,559,364 bytes
(229 MB) installed, downloaded in 11.9 s at 20.2 MB/s on this connection.

## What is not done

- No screen-context vocabulary harvesting (NOTES.md's layer 3: identifiers
  near the cursor via Accessibility) and no code-aware LLM formatting layer
  (layer 4) - out of scope for this package per the brief.
- No learning loops (auto-add a dictionary entry after two corrections,
  per-project vocabulary rotation, rule auto-disable after repeated undo) -
  `UserDictionaryStore` is the persistence primitive those would build on, but
  the loops themselves aren't implemented.
- `DevContextGate`'s ~150-word developer vocabulary and scoring weights
  (dictionary hit = 1.5x a plain dev word, memory decay 0.6 per step, app
  bonus 0.5, threshold 1.0) are a reasonable first cut, not measured against
  real dictation logs the way the boosting `minSimilarity` was measured
  against `TUNING_RESULTS.md` - there was no equivalent labeled dataset for
  topic gating to tune against.
- `HotkeyMonitor`'s hybrid tap/hold state machine does not special-case a long
  hold that starts while a tap-toggled recording is already in progress -
  that hold is currently ignored (the toggle-on recording just continues)
  rather than interrupting it.
- No notch UI, no Sparkle updates, no license/trial gating - all app-shell
  concerns, owned by the parallel track building `Sources/`.
- No onboarding pack picker: `UserDictionaryStore.enabledPacks` exists and is
  honored end to end, but nothing in the app sets it away from its default
  (`nil` = every pack on) yet.
- The 1721-term dictionary's recall/precision on `manifest_human.json` has
  drifted below the original 94.3%/97.1% tuning target as more packs were
  added (now 90.0%/81.8% - see "Bench with the pre-filter" above); this is a
  vocabulary-collision/`minSimilarity`-tuning problem, not a speed problem,
  and wasn't in scope for the pre-filter work.
