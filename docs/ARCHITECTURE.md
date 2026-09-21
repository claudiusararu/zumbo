# Zumbo architecture (app shell)

State: the app shell drives the real engine. Dictation works end to end -
hotkey, microphone, Parakeet, rules, paste, history - with the mock engine kept
only for the `--demo` screenshot paths.

## Targets and build

One target, `Zumbo`, macOS 14 minimum, Swift 6 language mode, strict
concurrency, plus the local Swift package `Engine/` (product `VesperEngine`)
declared in `project.yml` under `packages:` and listed as a target dependency.
FluidAudio 0.15.7 comes in transitively from `Engine/Package.swift`; Xcode
resolves it into `build/DerivedData`. Bundle id `com.claudiusararu.zumbo`. LSUIElement (no dock icon),
hardened runtime on, ad-hoc signed for Debug. Entitlement:
`com.apple.security.device.audio-input`. Info.plist carries
`NSMicrophoneUsageDescription` and `NSAppleEventsUsageDescription`. Sparkle is
still deliberately absent.

Regenerate and build:

    xcodegen generate
    ../hooppaper/scripts/safe-run.sh -m 6144 -t 540 -- \
      xcodebuild -project Zumbo.xcodeproj -scheme Zumbo -configuration Debug \
      -derivedDataPath build/DerivedData build

`project.yml` is the source of truth. `Support/Info.plist` and
`Support/Zumbo.entitlements` are generated from it and are gitignored, like the
`.xcodeproj`. Never hand-edit any of the three.

## Layout

    Sources/App        ZumboApp (SwiftUI App + NSApplicationDelegateAdaptor), AppDelegate, AppSettings
    Sources/Notch      panel, window, shape, state machine, views
    Sources/Dictation  EngineAdapter (DictationDriver), MockEngine, coordinator
    Sources/History    DictationHistoryEntry, HistoryStore (JSON on disk)
    Engine/            the local Swift package VesperEngine: capture, Parakeet,
                       dictionary, rules, dev-context gate, hotkey, text inserter

## Menu bar

`AppDelegate` owns an `NSStatusItem` with a template `waveform` symbol (plus a
small red dot overlay while meeting mode is on - see Notes and meetings
below) and the menu: Dictate (title flips to Stop Dictation while recording),
New Note, Meeting Mode (checkmark while on), History, Settings, Debug (Debug
builds only), Quit. History and Settings both open the
expanded notch panel, which is where both will live. There is no settings
window yet.

Debug submenu: Simulate hover, Simulate recording 3 s, Simulate done, Show
expanded. Launch arguments do the same thing without the mouse:

    Zumbo --demo hover|recording|done|expanded|expanded-grid|expanded-settings|expanded-detail
    Zumbo --demo-screen builtin|external|main   # Debug only, parks the pointer first
    Zumbo --demo expanded-settings --settings-category general|dictation|dictionary|models|license|about

`--demo recording` holds for 12 s so a screenshot can catch it. `--demo-screen`
exists because the panel follows the pointer, so a screenshot check has to be
able to choose the display. `--settings-category` only applies to
`expanded-settings`: it sets `NotchModel.initialSettingsCategory` before the
panel opens, which `ExpandedPanelView` reads once as its `@State` initial
value, so a per-category screenshot check does not have to click the sidebar
first.

The expanded header keeps exactly four icons on the History page - search,
grid/row toggle, gear (Settings), close - and one (close) on Settings. The
export icon that used to sit disabled between the layout toggle and close was
removed: it had no action and no place in a paid app.

## The panel

`NotchPanel` is a borderless, nonactivating `NSPanel`. Clear background, no
shadow, `isFloatingPanel`. Level is the assistive-tech high level (1500): the
menu bar is 25 and a fullscreen app can paint above that, so statusBar + 1 is
not enough. Collection behavior is `canJoinAllSpaces`, `fullScreenAuxiliary`,
`stationary`, `ignoresCycle`. `bringFront()` re-applies level and collection
behavior before every `orderFrontRegardless()`, because macOS resets them, and
the controller also calls it on `activeSpaceDidChangeNotification`.

`canBecomeKey` is false except in the expanded state, which has a search field.
Because the style mask is `.nonactivatingPanel`, the panel can take keys without
activating Zumbo, so the app the user was typing in stays frontmost and stays
the paste target. On collapse the panel resigns key and the previously frontmost
app is reactivated if needed. `canBecomeMain` is always false.

### State machine

`NotchController` owns the panel, the model and the state. States:
`idle`, `hover`, `recording`, `done`, `notice`, `expanded`.

- idle: nothing is drawn, on any display. On a MacBook the shape keeps the
  hardware notch rectangle as its footprint (so an expansion grows out of it),
  on a notchless display the height is zero. Fill opacity is 0 and mouse events
  are ignored. An invisible hot zone at top center, sized to the hardware notch
  on a MacBook, tracks hover.
- hover: one row of five quick actions (dictate, new note, meeting mode,
  history, settings), or - while meeting mode is on - a status line
  ("Meeting mode on, N min") and a Stop button in their place (see Notes and
  meetings below).
- recording: one row, [waveform] [live text] [stop button] [red dot] [elapsed].
  The stop button is `stop.circle.fill`; clicking anywhere on the panel also
  stops. Mouse events on, key status off.
- done: a checkmark draws itself with `.trim`, holds 500 ms, retracts.
- notice: one line plus an optional button, for a missing permission, a model
  that is still loading, or a failure. `showNotice(_:holdFor:action:)` holds it
  (4.5 s by default, 8 s for a permission) and retracts. It takes mouse events
  because the button has to be clickable, and a state change cancels it.
- expanded: 720 pt wide, two pages tracked by `ExpandedPage` on `NotchModel`
  (`.history` / `.settings`), not by a separate `NotchState`. History: search
  field, a row of app filter pills, then a row or grid of transcription
  cards. Settings: a back chevron, a left column of category pills, bound
  controls on the right. Escape (local monitor while key, global monitor if
  Accessibility is granted) goes back to History first when Settings is open,
  and only collapses on the next press; the X button or a click outside
  always collapses straight to idle, from either page. Reopening the panel
  always lands back on History.

Sizes come from `NotchMetrics.metrics(for:base:hasNotch:)`. Heights are derived
from content, never fixed: a small state is `topInset + 22 + 10`, where
`topInset` is the hardware notch height on a MacBook and 8 pt of padding
otherwise. That is how the content always starts right under the notch and why
there is no empty black band on notchless displays.

Screens: `NSScreen.hardwareNotchSize` uses `safeAreaInsets.top` plus
`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (nil on external displays, which
is what distinguishes a real notch from the menu bar inset). The panel re-homes
on the pointer's screen at every state change, on Space changes, and on screen
reconfiguration. It is centered on the middle of the hardware notch, not on the
screen, so it lines up exactly on a MacBook. There is only ever one panel.

Window geometry: the window is the shape plus 56 pt of slack left and right and
44 pt below, so a spring can overshoot without clipping. During a transition the
window is set to the union of both footprints, then tightened 620 ms later.
When the history detail panel is open, `NotchController.windowSize(for:)` adds
`detailPanelGap + detailPanelHeight` (8 + 260 pt) on top of the expanded
shape's own height - the shape's metrics never change, only the window does,
which is what keeps `NotchShape` from stretching over the second panel.

### Motion

Springs only. Expand `.spring(response: 0.34, dampingFraction: 0.62)` (overshoot),
collapse `.spring(response: 0.26, dampingFraction: 1.0)` (none). Content fades,
scales from 0.9 and unblurs 110 ms after the shape starts moving. The fill fades
out over the last 120 ms of a retract and comes back in 80 ms on the way out.
Reduce Motion (`accessibilityDisplayShouldReduceMotion`, watched live) replaces
all of it with 140 ms crossfades.

`NotchShape` is ours: bottom corners convex, top corners inverted concave
quarter circles that flare outward into the menu bar. Both radii are parameters
and animate through `animatableData`. They are clamped to half the current width
and half the current height, so the corners shrink with the shape and never snap
square mid morph.

Hover hysteresis: 120 ms to enter, 400 ms to leave, driven by a global
mouse-moved monitor (mouse monitors need no permission, and the panel ignores
mouse events while idle so a tracking area would never fire).

### Tooltips

`.help()` is AppKit-only and only fires for the active app, and Zumbo is
never active (nonactivating panel, `LSUIElement`), so every icon draws its own
tooltip (`Sources/Notch/HoverTip.swift`). It used to render in place with
`.overlay(alignment: .bottom)`, which drew the label on top of or right next
to the icon it belonged to - the grid toggle's "Show as a row" label landed
straight over the glyph. It is now a two-part preference-key design:
`HoverTip` (the `.hoverTip(_:)` view modifier) reports nothing visually, it
just publishes `(text, Anchor<CGRect>)` via `HoverTipPreferenceKey` once the
hover holds 350 ms; `hoverTipLayer()` (`HoverTipLayerModifier`), attached once
per panel root, consumes that and draws a single label per active tooltip
with `HoverTipLayout.center(for:text:in:)`: below the icon by default (6 pt
gap), above it only when there is no room below, horizontally centered on the
icon and clamped 8 pt inside the root's own bounds so it can never overflow
the panel or sit on a neighboring icon. Label size is estimated (6.2 pt per
character + 14 wide, 21 tall fixed) rather than measured with a hidden `Text`,
since every label is a short known string. The layer is
`.allowsHitTesting(false)`, so a tooltip can never intercept the mouse.

Attachment points must not nest, because a preference keeps bubbling past the
first ancestor that reads it (`overlayPreferenceValue` does not consume it) -
two nested layers would draw the same tooltip twice. There are five: the
`ExpandedPanelView` body root (header, filter pills, cards, the whole Settings
page all report up to this one layer), the `HistoryDetailPanelView` body root,
and three in `NotchRootView`'s small-state branches (`QuickActionsRow` in
`.hover`, `RecordingContent` - the stop button - in `.recording`,
`NoticeContent` in `.notice`); `.expanded` deliberately gets no layer of its
own at the `NotchRootView` level, since `ExpandedPanelView` already supplies
one for that entire subtree.

Label style: 10 pt medium, white 95% on a dark grey pill (white 16% fill, 1 px
white 12% border, 6 pt radius), 120 ms fade in via the same
`withAnimation(.easeOut(duration: 0.12))` that flips `HoverTip`'s `visible`
flag (the ambient transaction animates the new label's `.transition(.opacity)`
insertion in the overlay layer too).

## Engine

The app depends on one protocol, declared once, in the package
(`VesperEngine.DictationEngine`): `levels`, `start()`, `stop() -> String`,
`@MainActor`, `AnyObject`. The app's duplicate declaration is gone.
`DictationSession` already conforms.

`Sources/Dictation/EngineAdapter.swift` adds what the UI needs on top of that,
as the `DictationDriver` protocol: the `DictationState` stream
(recording -> transcribing -> done), `lastResult` (`DictationResult`: raw text,
final text, duration, transcription ms, dev-context decision and the per-stage
timings), `modelLoadProgress`, `isModelReady`, `dictionaryTermCount`,
`insert(_:)`, `apply(settings:)`, `reset()` and `transcribeFile(at:)`.
`EngineAdapter` wraps `DictationSession`; `MockEngine` conforms to the same
protocol so `--demo` still runs with no model and no microphone.

`DictationCoordinator` owns the order of a dictation: model readiness ->
microphone permission -> settings into the engine -> frontmost app captured as
the paste target -> start -> levels into the panel -> stop -> paste -> history
-> done. It is the only place that knows that order; the hotkey, the menu item
and the notch quick action all call the same `start()`/`stop()`.

### Speed

The expensive part of boosting is building the vocabulary context (CTC models,
spotter, rescorer), so `loadModel()` does it once at launch and keeps it warm;
a dictation never pays it. `prepareBoostingIfNeeded()` rebuilds it only when
the dictionary's contents change (hash signature), off the dictation path. One
model call per dictation returns both readings: `plainText` (pre-rescoring) and
`text` (boosted), so the dev-context gate still chooses between them without a
second pass.

Measured on this Mac, 5.7 s of speech (`recordings/human/en_02.wav`), Debug:

| Boost terms | setup (once) | asr | spotter | rescore | rules | total |
|---|---|---|---|---|---|---|
| 1721 (full starter pack) | 15344 ms | 88 | 738 | 2544 | 36 | 3371 ms |
| 150 | 438 ms | 87 | 269 | 216 | 4 | 574 ms |
| 40 | 223 ms | 82 | 234 | 56 | 1 | 373 ms |
| none | - | 85 | 0 | 0 | 1 | 85 ms |

So the per-dictation cost is almost entirely the boosting pass and it grows
fast with the term count. `DictationSession.maxBoostTerms` is the cap (0 = no
cap, the current default). It is not switched on yet because the starter JSON
carries no pack or priority field: the first 150 entries in file order are AI
vendors and social apps, while `Kubernetes` sits at index 295, `Docker` at 297
and `kubectl` at 907, so capping by file order would drop the developer terms
the boost exists for. Relevance-based capping needs that metadata.

### Waveform

`AudioCapture` emits RMS * 4, smoothed, at ~30 Hz. Measured through the same
formula on the human recordings, a quiet room stays under 0.02 and speech runs
0.04...0.12, so `WaveformBarsView` maps that window (noise gate at 0.02, full
scale at 0.12, curve 0.8) onto the bar height instead of treating the stream as
0...1. Below the gate every bar is a flat 2 pt line. Before this, the level
never exceeded the old 3 pt baseline and the bars only changed opacity.

### Rules

The numbers group no longer digitizes a lone number word used as a pronoun or
determiner. A run of two or more number words always converts ("one hundred",
"twenty five", "one point five"). A single word converts only after a currency
marker or an index noun (`version`, `step`, `page`), or in front of a measure
noun or plural count noun ("two seconds", "2 dogs"). "one" never converts on
its own, so "a custom one", "one day", "one second" and "one of them" stay
words.

Per-term `minSimilarity` from the dictionary JSON is now carried through
`DictionaryTerm` -> `VocabTerm` -> the vocabulary file FluidAudio reads, which
is what stops a common English word like "Jest" from firing on "test". It was
being dropped before, so every term ran at the global 0.75 floor.

## Permissions

Nothing blocks at launch and nothing crashes when a permission is missing; each
case is a notice in the notch with a button to the exact System Settings pane.

- **Microphone** (`AVCaptureDevice`, via `MicrophonePermission`): requested on
  the first dictation attempt, not at launch. Denied shows "Grant Microphone in
  System Settings" (`...?Privacy_Microphone`).
- **Input Monitoring** (`IOHIDCheckAccess`, for the hotkey's CGEvent tap):
  checked at launch. Missing means the hotkey is not installed and the notch
  shows "Grant Input Monitoring in System Settings"
  (`...?Privacy_ListenEvent`); the menu item and the quick action still work.
- **Accessibility** (`AXIsProcessTrusted`, for the Cmd-V that pastes):
  prompted once at launch when undecided. Without it `insert` still copies and
  returns `.copiedOnly`, and the notch shows "Grant Accessibility in System
  Settings" (`...?Privacy_Accessibility`).

## Hotkey

The engine's `HotkeyMonitor` on the persisted trigger, Right Option by default,
hybrid: a tap under 300 ms toggles recording on and the next tap stops it, a
longer hold is push-to-talk and stops on release. Both callbacks hop to the
main actor and call the coordinator.

## History

`HistoryStore` keeps a newest-first list in
`~/Library/Application Support/Zumbo/history.json`, capped at 5000 (see
Retention below for how the cap and daily purge interact), rewritten
after each mutation (a new dictation, a favorite toggle, a detail-panel edit or
delete). An entry holds the final text (`var`, editable from the detail
panel), the raw text, the timestamp, the target app's bundle id and name, the
word count, the recording duration, `isFavorite`, a `kind` (dictation, note or
meeting - see Notes and meetings below), an optional `title` and an optional
`endedAt`. Every field added after the first shipped format decodes to a safe
default when the key is missing via a custom `init(from:)`, so an old
`history.json` still loads. An empty transcript is
not recorded and not pasted.

`AppIdentity.normalize(bundleID:name:)` (`Sources/History/HistoryStore.swift`)
maps a system process (`UserNotificationCenter`, `loginwindow`, the
notification center agent) or an empty bundle id/name to `bundleID: nil,
name: "Unknown app"`, so the generic `app.dashed` glyph and one shared filter
pill cover all of them. `DictationCoordinator.frontmostTarget()` applies it at
capture time; `TranscriptionCard.cards(from:)` and the detail panel's chip row
apply the same mapping again when rendering, via `AppIdentity.displayName(for:)`,
so an entry captured by an older build still renders correctly.

The expanded panel's History page renders those entries as cards, row or grid
layout: the app's real icon from `NSWorkspace.icon(forFile:)`, abbreviated
relative time, word count, the `^N` shortcut badge for the first nine cards
(not bound to a real shortcut yet). The meta row is one fixed line that never
wraps - `ViewThatFits` tries icon+time+words+badge, then drops the badge, then
drops the word count too, as a grid card narrows. Each card's top-right
corner always shows two 12 pt icons at 55% white opacity (100% on their own
hover, never gated behind the card's hover state so they stay discoverable):
a star that toggles `isFavorite`, and a `doc.on.doc` that copies the text and
flashes "Copied" in the meta row for 1.2 s. Clicking the card's text area
(not an icon) opens the history detail panel (below) instead of copying.

Above the cards, a horizontal row of pills replaces the old tab row: "All N"
first and selected by default, then "Favorites N" (a `@State favoritesOnly`
combined with the app filter as an AND - favorites within the selected app),
then one pill per distinct normalized app identity, ordered by count
descending. Clicking an app pill filters the cards to that app; the search
field filters live by substring over the final text, the raw text and the app
name, within whatever pill/favorites selection is active. The row scrolls
horizontally when there are more pills than fit.

### History detail panel

Clicking a card's text area opens `HistoryDetailPanelView`
(`Sources/Notch/HistoryDetailPanelView.swift`): a second black rounded
rectangle (14 pt corners, same 720 pt width as the expanded panel, 260 pt
tall, 8 pt below it) drawn by `NotchRootView` in the same `NotchPanel` window,
right below the main shape - `NotchShape` itself never stretches over it, this
is a sibling view. `NotchController.setDetailEntry(_:)` mirrors
`setHistoryLayout`/`setExpandedPage`'s resize dance (grow to the union, animate,
trim once settled) so the level/space behavior stays identical; the
click-outside monitor and Escape both know about the extra rect (Escape closes
the detail before it touches Settings or collapses to idle).

Top row: a chip for the app (icon + name), relative time, word count and
`m:ss` duration, then right-aligned actions - Insert again (`arrow.down.doc`,
pastes into whatever app was frontmost via
`DictationCoordinator.insertIntoFrontmost(_:)`, which just calls the engine's
existing `insert(_:)`; Zumbo never activates so the frontmost app never
changed), Copy (flashes "Copied" 900 ms), the star toggle, Delete (`trash`,
arms on the first click with a 3 s window where the label reads "Sure?" and a
second click actually removes the entry and closes the panel), and X. Body is
a non-monospaced 13 pt `TextEditor` bound to a local `@State` copy of the
text; edits save to the entry 1 s after the user stops typing, and `onDisappear`
flushes any unsaved edit immediately so every close path (X, Escape,
click-outside, collapsing the whole panel) is covered, not just the X button.

## Notes and meetings

`DictationHistoryEntry` carries a `kind: EntryKind` (`.dictation`, `.note`,
`.meeting`, defaulting to `.dictation` on decode so an old `history.json`
still loads), an optional `title`, and an optional `endedAt` for a closed
meeting. A note or a meeting keeps growing text in `finalText` - a meeting's
is timestamped paragraphs ("10:34  <text>", built by
`HistoryStore.appendToMeeting`), simpler than a separate segments array and
enough to render "10:32 ..." lines directly in the editor. Neither kind is
ever pasted.

**New note**: the "New note" quick action (`note.text`), the menu item and
the optional note hotkey (below) all call `DictationCoordinator.startNote()`,
which sets `pendingNewNote` and runs the normal `start()`/`stop()` session
with `recordingContext = .note`. The recording row shows "Note" in place of
the live-text placeholder (`NotchModel.recordingContext`, read by
`RecordingContent` in `NotchRootView.swift`). On stop, `finish(transcript:)`
saves a fresh note (`HistoryStore.createNote`, title = first six words) and
never reaches the paste step. The expanded panel's Notes filter also has a
"+ Note" pill: it calls `HistoryStore.createNote()` directly (empty text) and
opens the detail panel on it with the editor focused
(`HistoryDetailPanelView.syncText` focuses `editorFocused` when a note's text
is still empty).

Dictating while the History detail panel is open on a note appends instead of
pasting: `DictationCoordinator.start()` checks
`notch.model.state == .expanded && detailEntryID` before deciding the
session's context, since that is the reliable signal that the panel (not
whatever app used to be frontmost) is where the user's attention is - a
nonactivating panel taking key status does not reliably change
`NSWorkspace.frontmostApplication`, so `frontmostTarget()` also returns
`isSelf` for the rare case it does, but the state check is what the append
path actually relies on. `HistoryStore.appendToNote` adds a blank-line
paragraph to the note's text. The detail panel also has "Save as note"
(`doc.on.doc` row's neighbor), which converts a dictation in place
(`HistoryStore.convertToNote`, same id, kind flips, title backfilled).

**Meeting mode** (rewritten 2026-09-18 for live chunked transcription and
speaker labels): the Meeting toggle switch in the hover row's quick actions
(`MeetingToggle` in `NotchRootView.swift` - a real track/knob switch, not a
button, so the on/off state is always visible) and the menu bar's "Start
Meeting"/"End Meeting" item both call `DictationCoordinator.toggleMeetingMode()`.
Turning it on **starts recording immediately** - there is no separate
"press the hotkey" step. It creates a meeting entry titled "Meeting, Sep 18
10:32" (`HistoryStore.createMeeting`), builds a fresh `MeetingSession`
(`engine.makeMeetingSession()`) and enters the notch's dedicated `.meeting`
state (`NotchController.startMeetingUI()`), a persistent row that never
retracts to `.idle` on hover-out - only the row's own Stop button (after a
"End meeting?" / "Keep going" two-step confirm, `MeetingRecordingRow`'s local
`@State`) or the menu item ends it. Hovering the compact row briefly swaps in
the quick-actions row and back (`NotchController.setMeetingHoverExpanded`,
same grow/trim resize dance as `setHistoryLayout`), without ever leaving
`.meeting`. The row: a green `person.2.fill` icon (so a meeting recording is
never mistaken for a plain dictation's red dot), the live `WaveformBarsView`
while recording or a slow green `PulsingDot` while paused, a live m:ss timer
that counts only recorded time (`meetingElapsedBase` + `meetingRunStartedAt`,
the latter nil while paused), a Pause/Resume button, and Stop. After each
transcribed chunk lands, a "Saved, N words" flash replaces the waveform for
~1.5 s (`NotchController.showMeetingSaved`) before fading back.

The live pipeline itself (chunking, diarization, alignment) lives in the
engine package - see Engine/README.md's "Meeting mode" section for
`MeetingChunker`/`SpeakerAligner`/`MeetingSession`/`SpeakerModelManager` and
the real-audio verification numbers. The app side only drives it:
`MeetingSession.paragraphUpdates` (an `AsyncStream`) is consumed by
`DictationCoordinator.handleMeetingParagraph`, which calls
`HistoryStore.appendMeetingChunk(newParagraph:)` - `newParagraph` (decided
by `MeetingSession`/`SpeakerAligner` from a speaker change or a
pause-then-resume) either starts a fresh "H:mm  Speaker N: text" paragraph or
appends to the one just written, so consecutive same-speaker chunks read as
one paragraph, not one per chunk.

The hotkey and Escape are meeting-aware: while `DictationCoordinator`'s
`meetingSession` is non-nil, `start()` (the hotkey's press handler) redirects
to `toggleMeetingPause()` instead of dictating - nothing is ever pasted while
a meeting is running - and `cancel()`'s Escape monitor is simply never
installed for a meeting (it is only installed inside the plain-dictation
`start()` path), so Escape cannot accidentally end one. Pausing drops
incoming audio before it reaches `MeetingSession`'s pipeline (the mic tap
keeps running so resume is instant) without touching the diarizer, so speaker
numbers stay stable across a paused gap; each resumed fragment starts a new
timestamped paragraph so the gap is visible in the note. A plain dictation or
note is refused while a meeting is recording, and vice versa - one microphone
session at a time.

Settings > Models has an "Add-ons" card with a "Speaker labels" row that is
the *only* place a download ever starts (see "Add-on store" below); Settings
> Dictation's "Meeting mode" card shows the same `AppSettings.labelSpeakers`
switch as a mirror, disabled with "Turn on the add-on in Settings > Models
first" until the add-on is installed. If a meeting starts wanting labels with
the add-on missing or off, it starts recording immediately without labels and
does **not** start a download on its own (`MeetingLabelAvailability
.unavailable`) - the disclosure notice gets an extra sentence, "Speaker
labels are off. Turn them on in Settings > Models.", and the note gets a
one-line footer, "Speaker labels were off for this meeting", appended when
the meeting ends (`HistoryStore.appendMeetingFooter`).

## Add-on store

The speaker-labels model (FluidAudio's streaming Sortformer diarizer) is an
"add-on": a versioned zip Zumbo downloads from our own Cloudflare R2 bucket
(`vesper-models`, public base URL `AddOnCatalog.baseURL` in
`Engine/Sources/VesperEngine/AddOnStore.swift`) - never from Hugging Face at
runtime. `AddOnStore` fetches the bucket's `catalog.json` (which manifest is
current for each add-on id), then that manifest (`AddOnManifest`: version,
sizes, SHA-256, `rootPath` - the path inside the zip the consumer loads),
downloads the zip with a `URLSessionDownloadTask` reporting byte-accurate
progress, verifies the SHA-256 with CryptoKit *before* anything else happens,
unzips with `/usr/bin/ditto -x -k` into a staging directory, confirms
`rootPath` is really inside it, then atomically swaps it into
`~/Library/Application Support/Zumbo/AddOns/<id>/v<version>/` and writes an
`installed.json` marker (version + size + rootPath). Install state at launch
is read from that marker with zero network calls
(`AddOnStore.installedMarker`). Cancelling stops the task and leaves no
partial files; `remove()` deletes the version directory and returns to
not-installed.

`SpeakerModelManager` wraps one `AddOnStore` for `speakerLabelsAddOnID`.
`makeDiarizer()` loads the installed, already-compiled Sortformer
`.mlmodelc` directly with `MLModel(contentsOf:)` and hands it to
`SortformerDiarizer.initialize(models:)` - **not**
`SortformerDiarizer.initialize(mainModelPath:)`, which calls
`MLModel.compileModel(at:)` and expects an uncompiled `.mlpackage`; verified
locally (2026-09-18) that pointing it at our compiled `.mlmodelc` throws ("A
valid manifest does not exist... Manifest.json"). `AppSettings.labelSpeakers`
now means "add-on installed and enabled": Settings > Models' toggle sets it
true the moment it starts a download, so the switch and the install finish in
lockstep; turning it off while installed keeps the files and just stops using
them. `zumbo-cli` gets `meeting --addon-dir <path>` (point at an unzipped
install directory for tests, bypassing the app's install location) and
`addon install <id>` (drives `AddOnStore` from the terminal with progress
printed - the exact path Settings > Models uses).

Packaging and upload: `scripts/package-addon.sh` (see Engine/README.md).

The menu bar icon gets a small red dot overlay view (not a composited image,
so the template waveform icon keeps its own tint) while meeting mode is on
(`AppDelegate.setMeetingBadge`, driven by `NotchModel.$meetingModeOn`, which
is still the "a meeting is active" flag even though the row it drives changed
states). The disclosure notice ("Meeting mode records through the
microphone...") shows once, the first time meeting mode turns on, gated by
`AppSettings.meetingDisclosureShown`; recording starts in parallel, not
gated on the notice being dismissed. `NotchNotice` (every notice, not just
this one) now sizes itself to its message via real text measurement
(`NotchMetrics.noticeSize`, `NSString.boundingRect`), widening up to ~520 pt
and wrapping to two or three lines instead of a fixed one-line truncation.

**Note hotkey**: a second, optional `HotkeyMonitor` in `AppDelegate`
(`noteHotkey`), rebuilt whenever `AppSettings.noteHotkeyTrigger` changes (nil
= off). It always calls `coordinator.startNote()`/`stop()`, has the same
tap/hold behavior as the main hotkey, and gets the same Input Monitoring
notice if a combo trigger's tap fails. `noteHotkeyTrigger` is encoded by hand
(`JSONEncoder`/`JSONDecoder` directly on the already-`Codable` `HotkeyTrigger`)
under its own `UserDefaults` key, since `HotkeyTrigger.load/save` always read
and write one fixed key and cannot hold two independent values.
`ShortcutRecorderRow` takes an `isNote` flag so Settings > General shows two
rows from one component ("Hold to dictate" and "Note shortcut", the second
with a "Clear" button instead of "Reset to Right Option"); recording a
trigger that matches the other row's current trigger is refused with an
inline "Already used for ..." message rather than applied.

## History filters and paging

The filter row gets "Notes N" / "Meetings N" pills (shown only when their
count is above zero) right after "Favorites", ahead of the per-app pills;
selecting one sets `ExpandedPanelView`'s `kindFilter` and clears the app
filter (mutually exclusive), and app pills are built only from `.dictation`
entries so a note/meeting never lands in the "Unknown app" pill. A card for a
note or a meeting shows a kind glyph (`note.text` /
`person.2.wave.2.fill`) instead of an app icon in the meta row, and its title
as a semibold first line above the body text. The detail panel's chip row
does the same for the app chip, and shows an editable title field under the
chip row for either kind.

Grid and row layout are paged independently of filtering: `filteredEntries`
runs search and every filter first, then `pagedEntries` caps it - 60 for the
grid (`gridVisibleCount`, a "Show more" tile at the end adds 60 per click) and
a fixed 20 for the row layout. `gridVisibleCount` resets to 60 whenever the
query or any filter changes, so a new filter never starts scrolled past its
own results.

## Reminders

A note (`.note`, also `.meeting` and a dictation converted to a note) can
carry one reminder: `reminderAt: Date?` and `reminderState: ReminderState?`
(`.pending`/`.done`/`.missed`) on `DictationHistoryEntry`
(`Sources/History/HistoryStore.swift`), both `nil` by default so an old
`history.json` still loads. A pending reminder makes the entry `isProtected`,
alongside favorites/notes/meetings, so retention and the on-disk cap never
drop a note with a reminder still waiting to fire.

**Entry point A, by voice.** `Engine/Sources/VesperEngine/ReminderParser.swift`
is a pure, testable parser (`Engine/Tests/VesperEngineTests/
ReminderParserTests.swift`): given a reference `Date` and `Calendar`, it reads
"this evening"/"tonight"/"this afternoon" (today at a fixed hour),
"tomorrow"/"tomorrow morning" (09:00 the default), "in N minutes/hours",
"next <weekday>", a bare "<weekday> morning/afternoon/evening", and an
explicit clock time ("at 7 p.m.", "3pm") that overrides a day phrase's own
default hour. A bare hour with no am/pm and no daypart word anywhere in the
text (`.ambiguous(Date, Date)`) asks rather than guessing; a resolved time
already in the past rolls forward (a day, or a week for a named weekday).
`DictationCoordinator.proposeReminderIfNeeded(noteID:text:)` runs it on every
note create/append (`finish(transcript:)`'s `.note` case) and, on a match,
replaces the normal "done" checkmark with a two-pill notch notice instead of
calling `notch.finish()` - `NotchController.showReminderNotice(...)` reuses
the existing `.notice` state and its sizing/hold-timer machinery.

**The two-pill notice.** `NotchNotice` (`Sources/Notch/NotchController.swift`)
gained `secondaryActionTitle` alongside the original single `actionTitle`,
and `NotchModel` a matching `noticeSecondaryAction` closure; both wrap back to
`transition(to: .idle)` the same way the primary one always did.
`NotchMetrics.noticeSize(for:hasSecondaryButton:)` widens the shape for the
extra pill. `NoticeContent` (`Sources/Notch/NotchRootView.swift`) renders the
second pill muted-white beside the white primary one, and swaps the
permission triangle for a green `bell.fill` whenever the message reads as a
reminder (the notice carries a secondary pill, or the text starts with
"Reminder"/"Missed reminder"/"Note saved. Remind"). A clean parse shows "Note
saved. Remind you Thu 7:00 PM?" (Set reminder / No); an ambiguous one shows
"Remind you at 7:00 AM or 7:00 PM?" with the two clock times themselves as the
pills. Either accepted path calls
`ReminderScheduler.setReminder(id:at:)` and flashes a plain one-pill
confirmation, "Reminder set for Thu 7:00 PM".

**Entry point B, by hand.** The detail panel's chip row
(`Sources/Notch/HistoryDetailPanelView.swift`) gets a `bell`/`bell.fill` icon
button (note/meeting kinds only, same place the star/copy icons sit) that
opens `Sources/Notch/ReminderPickerView.swift` in place of the text editor -
same self-contained, headlessly-renderable pattern `TeachFormView` already
uses, same lighter white-6%-surface/10pt-radius card. Quick pills ("In 1
hour", "This evening", "Tomorrow morning", "Next Monday") set a `DatePicker`
(`.field` style, date + hour/minute) that "Set" commits. A pending reminder
also shows as a chip in the row ("Thu 7:00 PM" with a small x to cancel) and,
on the History card itself (`TranscriptionCard.reminderStamp`,
`Sources/Notch/ExpandedPanelView.swift`), a short "Thu 7 PM" bell badge in the
meta row - same drop-first priority as the shortcut badge as a grid card
narrows. A "Reminders" pill appears in the filter row after "Meetings" once
at least one reminder is pending (`HistoryStore.pendingReminders`, soonest
first); selecting it is mutually exclusive with the app/kind filters, same as
"Notes"/"Meetings".

**Firing.** `Sources/App/ReminderScheduler.swift` owns both clocks for every
pending reminder: a `UNUserNotificationCenter` request (title = the note's
title or "Reminder", body = the first 120 characters of its text), scheduled
with a `UNTimeIntervalNotificationTrigger` keyed by the entry's `UUID` so it
can be cancelled or replaced by id, and an in-process `Task` per reminder
(`arm(_:)`) that sleeps until the reminder's time and then calls
`NotchController.showReminderNotice(...)` with "Reminder: <first 60 chars>"
and Done/Snooze 10 min pills (held 30 s or until clicked). Notification
permission is requested lazily, the first time any reminder is ever set, not
at launch; `NotchModel.notificationsDenied` (set from
`ReminderScheduler.authorizationStatus`, refreshed at launch via
`getNotificationSettings`) makes the picker show one explanatory line and an
"Open System Settings" pill instead of a silently inert "Set" once denied.
`AppDelegate.applicationDidFinishLaunching` calls
`reminders.checkMissedReminders()` (anything still `.pending` whose time has
already passed - the Mac was asleep, or the app was not running - is marked
`.missed` and shown once more via the same firing notice, prefixed "Missed
reminder") before `reminders.start()` arms live timers for everything still
pending, so nothing already-fired notification double-fires its notch notice.

## Retention

`AppSettings.retentionDays` (7, 30, 90, or 0 for forever, default 30) drives
`HistoryStore.purgeExpired()`, called once at launch
(`AppDelegate.applicationDidFinishLaunching`) and once a day
(`HistoryStore.startRetentionTimer()`, a repeating `Timer`). A favorite, a
note or a meeting (`DictationHistoryEntry.isProtected`) is exempt from both
retention and the on-disk cap, which moved from 500 to 5000
(`HistoryStore.cap`) - `enforceCap()` drops the oldest unprotected entry first
and only reaches into protected entries as a last resort if every entry
somehow is one. Settings > General's "History" card has the four-option
segmented retention control plus a "Clear history" row: the button arms on
the first click ("Sure?", 3 s window) before `HistoryStore.clearHistory()`
removes everything except favorites/notes/meetings, and a small `Menu` next
to it offers "Everything" (`clearHistory(includingProtected: true)`).

## Settings

`AppSettings` (`Sources/App/AppSettings.swift`) holds the hotkey trigger (via
the engine's own `HotkeyTrigger.load/save`), the five rule toggles, the
developer mode, the enabled dictionary packs, `playSounds` (default on, no
sound implementation behind it yet) and `showMenuBarIcon` (default on, drives
`NSStatusItem.isVisible` live through a Combine `sink` in
`AppDelegate.buildStatusItem()`) in `UserDefaults`. The values are pushed into
the engine at the start of every session (`EngineAdapter.apply(settings:)`
sets `rulesConfig` and `developerMode`), so binding `AppSettings`' `@Published`
properties directly from the Settings UI is enough to reach the engine on the
next dictation - no separate wiring.

The Settings UI lives inside the expanded panel as its own page
(`ExpandedPage.settings` on `NotchModel`, `NotchController.setExpandedPage(_:)`
drives the resize the same way `setHistoryLayout` does), opened by the gear
icon in the History header and closed by the back chevron. Same 720 pt width
as History, height 480 pt on a notchless display via
`NotchMetrics.expandedSettingsBodyHeight` - unchanged by the redesign below,
only the right column's content got denser.

Redesigned to match the Supaste card language instead of bare checkboxes on
black (`Sources/Notch/SettingsPanelView.swift`, category enum still in
`ExpandedPanelView.SettingsCategory` since it is that view's own `@State`
type). Left column: General/Dictation/Dictionary/Models/License/About, each a
capsule row with an SF Symbol (gearshape, waveform, book, cpu, key,
info.circle) plus the label, selected = white pill with black text, same
treatment as the History filter pills. Right column scrolls (still through
`OverlayScrollView`) and every category starts with a 15 pt semibold page
title and an 11 pt white-50% one-sentence subtitle
(`SettingsPanelView.categoryHeader`, text from `SettingsCategory.rawValue` /
`.subtitle`) before its `SettingsCard`s: white 6% fill, 12 pt radius, 14 pt
padding, 1 px white 7% border, a 12 pt semibold title, then `SettingsRow`s
(12 pt white-92% label, an optional 10.5 pt white-60% description under it, a
right-aligned control) separated by 1 px white 6% `SettingsDivider`s.
`PillToggle` is a custom 34x20 switch - track white 22% off (kept clearly
visible against black rather than nearly-invisible), `SettingsTheme.accent` (a
warm gold, the one accent color on the page) on, a white-85% knob with a soft
shadow, spring-animated - used for every boolean; `SettingsSegmented` is the
same white-pill-on-translucent-track language for the Developer mode picker,
never the accent (accent means "on", not "selected"). Disabled affordances
(Launch at login, Re-download, Check for updates, the Dictionary "Add" button,
License's Activate) share one `.soon(_:)` view modifier:
`.disabled(true).opacity(0.45).hoverTip(_:)`.

- **General**: a "Shortcut" card hosting `ShortcutRecorderRow` (restyled to
  drop its own duplicate heading now that the card supplies one, and to show
  "Hold to dictate" / "Tap to toggle, hold for push-to-talk" as a proper
  label+description row); a "Behavior" card with Launch at login (disabled
  stub), Play sounds (`AppSettings.playSounds`) and Show menu bar icon
  (`AppSettings.showMenuBarIcon`).
- **Dictation**: a "Clean speech" card (one toggle, `rules.cleanSpeech`,
  description lists what it drops); a "Formatting" card with the other five
  rule toggles, each with a live before/after example in its description
  ("two hundred bucks" becomes "$200", etc.); a "Developer mode" card with the
  Auto/Always/Off `SettingsSegmented` and a description of what Auto does.
- **Dictionary**: a "My words" card (empty state text, a disabled "Add" button
  with a "coming next" tooltip); a "Packs" card with "Developer preset"/"All"
  preset chips above a 2-column grid of pack tiles. Term counts and one-line
  descriptions come from `Sources/Notch/PackCatalog.swift`, a static table
  (the starter vocabulary JSON lives in the `VesperEngine` package target, not
  reachable as a countable resource from the app target at runtime) -
  regenerate it from `seeds/packs/*.json` with the Python snippet in that
  file's doc comment whenever a pack's terms change.
- **Models**: a "Parakeet" card - name, "On device, 1.0 GB", a status dot
  (`SettingsTheme.statusGreen` when `NotchModel.modelReady`, threaded through
  `ExpandedPanelView.modelReady` -> `SettingsPanelView.modelReady`, white 25%
  otherwise) plus a disabled "Re-download" row.
- **License**: a "Trial" card with a static 3-of-3-days progress bar
  (`TrialProgressBar`, reads nothing real yet); a "License key" card with a
  monospaced text field (placeholder `ZUMB-XXXX-XXXX-XXXX-XXXX`), a disabled
  "Activate" pill and "Buy Zumbo" - the one filled (white/black) button on
  the page, opens `https://zumbo.app` (placeholder) via `NSWorkspace`.
- **About**: version/build read from `Bundle.main.infoDictionary`; a disabled
  "Check for updates"; an "Acknowledgements" row that expands inline (no
  navigation) to OpenSuperWhisper/OpenDictation (MIT, copyright lines from
  `references/*/LICENSE`), FluidAudio (Apache License 2.0, FluidInference) and
  NVIDIA Parakeet (CC BY 4.0, NVIDIA Corporation).

The body scrolls vertically; `NotchPanel.usesVerticalScroll` (renamed from
`isHistoryGridMode`, also true for the History grid layout) bypasses the
panel's horizontal scroll-axis swap while Settings is open.

Both the Settings body and the History grid scroll through
`OverlayScrollView` (`Sources/Notch/OverlayScrollView.swift`), an
`NSViewRepresentable` around a plain `NSScrollView` instead of a SwiftUI
`ScrollView`: `scrollerStyle = .overlay` so the indicator never reserves
layout width, and a custom `ThinOverlayScroller` (`NSScroller` subclass)
draws a 4 pt wide, rounded, white-at-25%-opacity knob with no track. The
`Coordinator` watches `NSView.boundsDidChangeNotification` on the content view
and animates the scroller's `alphaValue` in on any scroll, then back out ~800
ms after the last one - chosen over the plain SwiftUI `ScrollView` +
`.scrollIndicators()` because that API cannot restyle a scroller's width,
color or fade timing, and this needed to be reliable inside a borderless,
nonactivating `NSPanel`.

## Onboarding

An eight-step first-launch walkthrough, its own `NotchState.onboarding`
(`Sources/Notch/NotchGeometry.swift`), driven by `OnboardingCoordinator`
(`Sources/Onboarding/OnboardingCoordinator.swift`) and drawn by
`OnboardingRootView` (`Sources/Notch/OnboardingView.swift`). `AppSettings
.onboardingCompleted` (default false) gates it at launch
(`AppDelegate.presentOnboardingIfNeeded()`, skipped for `--demo` and
`--transcribe-file`); the DEBUG build also accepts `Zumbo --onboarding` to
force it regardless. Settings > About's "Run setup" card calls
`OnboardingCoordinator.restart()`, which resets every onboarding field and
transitions straight from wherever Settings was (closing it) to step 1.

Steps: 1 Welcome (three sell facts, no adjectives), 2 Microphone, 3
Accessibility, 4 Keyboard (Input Monitoring), 5 Your key (the hotkey), 6 What
you dictate most (picks starter packs), 7 Try it (a real, un-pasted dictation
shown inline), 8 Start (trial or buy). Copy is exactly NOTES.md's "Onboarding
sells"/"Onboarding last step"/"Onboarding copy correction" - facts only, and
step 6/7 never name a concrete term except the person's own transcript in
step 7.

Step 4 exists because on Darwin 25 (measured 2026-09-20, the day of the
Vesper -> Zumbo rename) macOS delivers `NSEvent.addGlobalMonitorForEvents`
key events - the global Escape-to-cancel monitor in
`DictationCoordinator.installEscapeMonitor()` - only when
`CGPreflightListenEventAccess()` is true; Accessibility trust alone is not
enough. The renamed bundle id starts with no Input Monitoring grant, so every
fresh install needs this step or Escape silently does nothing outside
Zumbo's own panel.

### Panel

`NotchMetrics.onboardingSize` (560 x 360 pt) is a fourth size tier above
`.expanded` in `NotchController.weight()` (4, vs. 3), so entering or leaving
it always plays the full expand/collapse spring, same shape and black
surface as every other state. It never retracts on its own: `transition(to:)`
takes key status for it (so the inline shortcut recorder and the license key
field can type) but deliberately skips `installExpandedMonitors()` - no
click-outside, no Escape handler - and `NotchController.pointerMoved()`'s
hover hysteresis has no case for it, so hovering off does nothing either.
Only `OnboardingCoordinator.finish()` (Start step) or its "Skip" links call
`transition(to: .idle)`.

### Compact row

While a permission step (2, 3 or 4) is showing and another app takes focus -
System Settings, opened by that step's own button - the panel compacts to a
small row (`NotchMetrics.onboardingCompactSize`, 280 x 44 pt: "Step N of 8,
<name>" and a "Back to setup" pill) instead of sitting on top of it.
`OnboardingCoordinator` observes `NSWorkspace.didActivateApplicationNotification`;
since Zumbo is a nonactivating panel and never activates itself, any other
app becoming active while onboarding is open on a permission step is an
unambiguous trigger. `NotchController.setOnboardingCompact(_:)` mirrors
`setHistoryLayout`'s resize dance (grow to the union, animate, trim once
settled) without leaving `.onboarding`. Restoring happens from the pill
(`onboardingRestoreFromCompactRequest`), from the coordinator's 1 s
permission poll succeeding, or (belt and suspenders, per the owner)
`NSApplication.didBecomeActiveNotification`.

### Permission steps and the three-state mark

Steps 2, 3, 4, 5 and 7 all show the same mark (`OnboardingMark` in
`OnboardingView.swift`): a grey outline circle before anything was asked, a
green `checkmark.circle.fill` (`SettingsTheme.accent`) once granted or done,
a red `xmark.circle.fill` once asked and refused (mic/accessibility/Input
Monitoring only - steps 5 and 7 only ever reach grey or green). Mic reuses
`MicrophonePermission.request` (the system prompt); Accessibility reuses
`PermissionPanes.open(.accessibility)` and polls
`TextInserter.isAccessibilityTrusted()` every second while the step shows,
ticking itself with no relaunch. Input Monitoring (step 4) mirrors
Accessibility exactly: `PermissionPanes.open(.inputMonitoring)` on the pill,
`CGRequestListenEventAccess()` once when the step appears (so macOS lists
Zumbo in that pane), and a 1 s poll on `CGPreflightListenEventAccess()`. All
three are required: Continue stays disabled until granted, and (owner
override, 2026-09-18, applies to Input Monitoring too) there is no "Skip" on
any of them.

### The hotkey (steps 5 and 7)

`AppDelegate.installHotkey()`'s press/release closures check
`notch.model.state == .onboarding` first and route to
`OnboardingCoordinator.hotkeyPressed()/hotkeyReleased()` instead of the
normal `DictationCoordinator.start()/stop()`; every other onboarding step
ignores the hotkey. Step 5 just flips the mark to granted - no audio, no
engine call. Step 7 calls into `DictationCoordinator` for real:
`start()`/`stop()` both check `notch.model.state == .onboarding` first and
branch to `startOnboardingTry()`/`stopOnboardingTry()`, a real engine session
that skips the paste path, history and the `.recording` notch state
entirely - the panel stays on `.onboarding` and the result lands in
`NotchModel.onboardingTryText`. Corrected-word underlining
(`onboardingTryHighlights`, same dashed green `CorrectionLayoutManager`
underline as Teach, via `SelectableTextView`'s new `editable: Bool = true`
parameter set to `false` here) is an approximation: it matches the
transcript's words against the live dictionary (`dictionaryTerms()`), since
the engine does not yet report which words a given transcript's boosting
pass actually corrected.

### Step 6 and packs

`OnboardingArea` (`Sources/Onboarding/OnboardingModels.swift`) is the eight
tiles' data: title, the starter packs it turns on (NOTES.md "Onboarding step
5"), and one generic sentence (NOTES.md "Onboarding copy correction", no
example terms). Continuing with at least one pick sets
`AppSettings.enabledPacks` to the union of the picked areas' packs;
continuing with none, or "Skip, use the developer set", leaves the default
developer set untouched.

### Finish

"Start your 3-day trial" writes `AppSettings.trialStartedAt = Date()`
(`UserDefaults` for now - a comment marks where the License work moves it to
the Keychain) and finishes; "Buy a license" opens `OnboardingCoordinator
.buyURL` (`LicenseEndpoints.production.checkoutURL`, `https://zumbo.app/buy`)
without finishing, so both buttons stay available.
The "Have a key?" field's Activate button calls a stub
(`OnboardingCoordinator.activate(key:)`), mirroring Settings > License's own
disabled "Activate" - there is no licensing backend yet (NOTES.md "Licensing
backend"). `finish()` sets `onboardingCompleted = true`, retracts the panel,
and requests notification permission - the only place in the app that
does - before showing one `UNUserNotificationCenter` notification ("Zumbo is
ready. Press Right Option anywhere."); denial is silent.

## Licensing

Full contract for the (not yet built) Cloudflare Worker: `docs/LICENSING.md`.
Summary of the app side, all real:

- `LicenseState` (`Sources/App/LicenseState.swift`) is the one source of
  truth: `.trial(endsAt:)` / `.trialEnded` / `.licensed(tier:, machines:)` /
  `.unlicensed`, computed from the Keychain (service
  `com.claudiusararu.zumbo`, accounts `trial` and `license`) at launch, at
  midnight, and on `didBecomeActiveNotification`.
- Onboarding step 8's "Start my 3-day trial" is unchanged - it still writes
  `AppSettings.trialStartedAt`. `LicenseState` migrates that value into the
  Keychain the first time it sees it (once; the Keychain wins after that).
- Hard gate (NOTES.md: no free tier): `status.isLocked` (`== .trialEnded`)
  blocks the hotkey, the menu's Start Dictation/New Note/Start Meeting, and
  the notch's quick actions, showing `NotchState.locked` instead - lock
  icon, "Your 3-day trial has ended.", "Buy a license" (opens
  `LicenseEndpoints.production.checkoutURL`) and "Enter key" (opens Settings
  > License with the key field focused). Escape or a click outside retracts
  it, same as `.expanded`; the next gated action shows it again. Nothing
  else in the app is gated - history, notes, settings stay fully usable.
- One day before the end and on the last day, `LicenseState.
  finalStretchNoticeIfDue()` returns "Trial ends tomorrow" / "Trial ends
  today" once per calendar day, checked from the dictation start path (not a
  timer) so it only ever fires from a real attempt to dictate; shown as an
  ordinary 5 s `NotchNotice` with a "Buy a license" pill, never blocking.
- Settings > License (`LicenseSettingsView` in `Sources/Notch/
  SettingsPanelView.swift`) shows a status row first (green dot for trial or
  licensed, red for ended), then the key field (uppercase-as-typed,
  auto-hyphenated every 4 characters via `LicenseKeyFormatter`, Activate
  pill lights up at 19+ formatted characters) with a spinner while
  `LicenseState.isActivating`, and once licensed: "Activated on this Mac" +
  machine name, a "Deactivate this Mac" text link behind a two-step confirm,
  and no more key field. "Buy a license" stays visible only in the trial
  states.
- Activation: `LicenseClient` protocol, `HTTPLicenseClient` (real,
  `docs/LICENSING.md`) and `MockLicenseClient` (accepts only
  `ZUMB-TEST-TEST-TEST-TEST`, tier `single`) selected by `LicenseClient.
  make()` from `ZUMBO_LICENSE_MOCK=1` / `--license-mock`, Debug builds only. Tokens are
  base64-JSON-payload-plus-Ed25519-signature (`LicenseTokenPayload` /
  `SignedLicenseToken` in `Engine/Sources/VesperEngine/LicenseCore.swift`),
  verified against an embedded public key (`Sources/App/
  LicensePublicKey.swift`, a 32-zero-byte placeholder until
  `scripts/license-keys.md` is run). A verified token keeps working offline
  until `expiresAt + 30 days` (`LicenseGrace`); a weekly background
  `/validate` silently refreshes it, and a 401/revoked response drops the
  cached token, re-evaluates status, and shows "Your license was
  deactivated" once (`LicenseState.onLicenseDeactivated`).
- `zumbo://activate?key=...` (project.yml `CFBundleURLTypes`) opens
  Settings > License pre-filled and activates immediately.
- Owner-only launch argument `--trial-state ended|lastday|day2` overrides
  the computed status everywhere (menu line, notch, Settings), including in
  Release builds, so every state is reachable without waiting three days or
  faking the Keychain by hand.
- Pure logic - trial-window math (calendar days, DST-safe), token
  verification, the 30-day grace window, key formatting - lives in
  `Engine/Sources/VesperEngine/LicenseCore.swift` and is covered by
  `Engine/Tests/VesperEngineTests/LicenseCoreTests.swift` (`swift test`), not
  the app target, since the app has no test target of its own yet.

## Feedback

Settings > Feedback (`FeedbackSettingsView` in `Sources/Notch/
FeedbackSettingsView.swift`) sends praise, problems and feature requests to
the same Worker as licensing, `POST LicenseEndpoints.production.baseURL/
feedback` (`zumbo-api/src/routes/feedback.ts`). One card: a `SettingsSegmented`
for Praise/Problem/Feature request, a `SelectableTextView` text area with a
"0 / 4000" counter that turns red past the limit, an optional email row, a
"You may quote me" `PillToggle` (Praise only, off by default), and a Send
pill that clears the form and shows a 6 s "Thank you" line on success.
`FeedbackClient` (`Sources/App/FeedbackClient.swift`) mirrors
`HTTPLicenseClient`'s request/response style and maps the Worker's error
codes (429 rate limit, 422 malformed) to plain-word text under the button.
Only `appVersion`, `macOSVersion` and `licenseState` (from `LicenseState.
status`) ride along - no other data. The menu bar's "Send feedback..." item
and `AppDelegate.showFeedback()` open Settings straight to this page, same
pattern as the `zumbo://activate` deep link opening Settings > License.

## Updates

Sparkle 2 (pinned `from: 2.10.0` in `project.yml`'s `packages:`), with the
whole user interface replaced. Zumbo is an LSUIElement app whose only surface
is a nonactivating `NSPanel`; every stock Sparkle window would need an
activating window and would pull focus out of whatever the owner was typing
in. So `Sources/App/UpdateDriver.swift` implements `SPUUserDriver` itself and
draws each step as the notch's existing one-line notice.
`SPUStandardUserDriver` is never used.

What the owner sees, all in the notch:

- "Zumbo 1.0.2 is available", a white "Update" pill, a muted "Later" pill and
  a small "x".
- "Update" starts the download: "Downloading, 4 MB of 10 MB" with a thin
  progress line along the bottom edge of the notice (`NotchNotice.progress`,
  drawn as an overlay so it adds no height and never changes the notice's
  measured width). Then "Installing...", then Sparkle's own Autoupdate helper
  quits and relaunches the app. That works with no Dock icon: the helper
  relaunches the bundle directly and needs no extra entitlement.
- "Later" writes `AppSettings.updateSnoozeUntil` 24 hours out. Background
  checks inside that window answer `.dismiss` and draw nothing. A manual check
  from Settings > About ignores the snooze.
- Errors are plain words in the same notice: "Could not download the update.
  Try again later."
- Release notes are never shown. The marketing site carries them; the two
  release-note delegate methods are no-ops so the session proceeds.

Any exit from the notice that is not one of the two pills (the "x", Escape,
the hold expiring) still owes Sparkle an answer, so `UpdateController`
subscribes to `NotchModel.$state` and resolves the pending reply as
`.dismiss` + snooze the moment the panel leaves `.notice`. Leaving it
unresolved would wedge the update session.

Settings > About's "Check for updates" row calls
`AppSettings.checkForUpdatesRequest`, wired by `AppDelegate` to
`SPUUpdater.checkForUpdates()`. A manual check that finds nothing shows "You
are up to date, 1.0.1"; a background one stays silent. `--demo` runs never
build the updater at all, so a screenshot pass cannot reach the network or
draw a notice over the state being captured.

Configuration lives in the Info.plist, generated from `project.yml`'s
`info.properties`: `SUFeedURL` `https://updates.zumbo.app/appcast.xml`,
`SUEnableAutomaticChecks` true, `SUScheduledCheckInterval` 86400 (once a day),
`SUAutomaticallyUpdate` false (nothing downloads until the owner presses
Update), and `SUPublicEDKey`.

Signing: updates are signed with an EdDSA (ed25519) key pair.

- The **public** key is `SUPublicEDKey` in `project.yml`, in the repo, in
  every shipped app bundle. That is the whole point of it.
- The **private** key exists in exactly one place: the login keychain on the
  owner's Mac, under "Private key for signing Sparkle updates", put there by
  Sparkle's `generate_keys`. It is never in the repo, never in a file, never
  in a log, never in CI. `scripts/release.sh` calls `sign_update`, which
  reads it from the keychain and prints only a signature.

`scripts/release.sh` builds the DMG, notarizes it, signs it with that key and
writes the `sparkle:edSignature` into `dist/appcast.xml`, then uploads the DMG
and the appcast to the R2 bucket `zumbo-updates` behind `updates.zumbo.app`.
See docs/RELEASE.md.

The DMG also bundles the speech models so dictation works offline from the
first launch: `parakeet-tdt-0.6b-v3-coreml` (~461 MB),
`parakeet-ctc-110m-coreml` (~98 MB) and `silero-vad-coreml` (~1 MB) go into
`Zumbo.app/Contents/Resources/Models`, and
`VesperEngine.BundledModels.installIfNeeded()` copies them into FluidAudio's
own cache (`~/Library/Application Support/FluidAudio/Models`) on first launch.
A copy rather than a bundle path because only one of FluidAudio 0.15.7's three
loaders takes a directory override - see the type's doc comment. Speaker
labels (sortformer, ~230 MB) stay an on-demand add-on from
`models.zumbo.app`, never bundled.

## Stubbed

- Dictionary: pack toggles are real, "My words" is a card with an empty state
  and a disabled "Add" button, no per-word editor yet.
- Models: the Parakeet card's status dot and "On device, 1.0 GB" text are
  real; "Re-download" is a disabled stub. About: version/build are real,
  Acknowledgements is real (reads `references/*/LICENSE`), "Check for
  updates" is real (see "Updates" below).
- Play sounds (`AppSettings.playSounds`) persists but nothing plays a sound
  yet. Launch at login is still a disabled stub (needs a login-item API).
- The expanded header has no export/share icon any more (removed, it had no
  action). Search, the grid toggle, the gear (Settings) and the X all work.
- Live text during recording is "Listening..." then "Transcribing...": the
  engine does not stream partials.
- The `^1`...`^9` badges on the history cards are not bound to shortcuts.
- Onboarding: built (see "Onboarding" above); a headless contact sheet of
  all seven steps was rendered before the build (`ImageRenderer`, a
  standalone harness with fake state - not the real `NotchModel`-backed
  views), and the built, installed app was launched once and confirmed as a
  single process. The compact-row trigger, the live permission polls and the
  "Try it" underline were not clicked through interactively on screen in
  this session. Model download progress is logged, not shown, and the
  Fn/Globe "Press Globe key = Do Nothing" note is still only in the READMEs.
- Boost-list capping (`maxBoostTerms`) is implemented but off, pending pack
  metadata in the vocabulary JSON.
- Licensing: app side built against a
  placeholder backend (see "Licensing" above and docs/LICENSING.md); the
  Cloudflare Worker and Dodo Payments checkout do not exist yet.

## Verified on this machine

Two displays: a 3440x1440 notchless main display and the built-in 1512x982 with
a 185x32 pt notch. Screenshots in this folder, all taken from the built app:

- `checkpoint-1.png` recording on the notchless main display, over a fullscreen
  window, top 300 px.
- `checkpoint-2-notch.png` recording on the MacBook display, panel over the menu
  bar, content starting under the notch.
- `checkpoint-3-expanded.png` expanded panel with the search field focused.
- `checkpoint-4-idle.png` idle on the MacBook display: nothing drawn.
- `checkpoint-5-integrated.png` the done state right after a real dictation was
  pasted into TextEdit, on the MacBook display.
- `checkpoint-6-waveform.png` the recording row with the meter following the
  level stream (bars scale in height, no longer a flat line).
- `checkpoint-8-settings.png` the expanded panel's Settings page
  (`--demo expanded-settings`): back chevron, category pills, the General
  category's hotkey picker and disabled "Launch at login" stub.
- `checkpoint-9-filters.png` the expanded panel's History page
  (`--demo expanded`) with the app filter row over three seeded dictations
  across three different apps.
- `checkpoint-11-cards.png` the History row layout (`--demo expanded`) with
  the Favorites and "Unknown app" pills, and the corner star/copy icons on
  every card.
- `checkpoint-12-grid-scroll.png` the History grid layout
  (`--demo expanded-grid`).
- `checkpoint-13-detail.png` the history detail panel
  (`--demo expanded-detail`), top 820 px: chip row, action buttons, the
  editable text body, drawn below the expanded panel in the same window.
- `checkpoint-14-settings-general.png`, `-dictation.png`, `-dictionary.png`,
  `-about.png` (`--demo expanded-settings --settings-category <name>`, top
  560 px): the redesigned Settings page's card layout. `-models.png` and
  `-license.png` were dropped: both captures raced the panel's fade-in
  (window resized to full width before `contentVisible` finished animating
  in, so `screencapture` caught a half-transparent frame) and were not
  retaken - further demo launches were stopped mid-check because each one
  pops a visible window on the owner's screen. The Models and License card
  layouts are unverified on screen; General, Dictation, Dictionary and About
  confirm the same `SettingsCard`/`SettingsRow`/`PillToggle` pattern renders
  correctly, and Models/License are built from the same components.
- A tooltip screenshot with a label visible (`cliclick`-driven hover) was
  planned but skipped for the same reason - no further launches.

Window level 1500, alpha 1 and the exact panel frames were read back from
`CGWindowListCopyWindowInfo` during each capture (checkpoints 1-13; the
Settings checkpoints used the same technique, filtered by the demo process's
own PID rather than owner name, since the real installed app and a debug
build both report `kCGWindowOwnerName == "Zumbo"`).

### End-to-end check, unattended

`Zumbo --transcribe-file <wav>` is a hidden launch argument: it loads the
model, runs the whole post-capture pipeline on a WAV (no microphone) and pastes
the result into the frontmost app, then writes history like any other
dictation. With TextEdit frontmost and
`../dictation-spike/recordings/human/en_02.wav`:

    paste 8 s after launch (model load + warm boosting setup included)
    TextEdit document: "Use kubectl to list the pods on the Kubernetes cluster."
    stages: asr 87 ms, spotter 740 ms, rescore 2540 ms, rules 44 ms,
            boost setup 4646 ms (at launch, not in the dictation)
    history.json: newest entry, app TextEdit, 10 words

TextEdit's text was read back with AppleScript, so both "kubectl" and
"Kubernetes" are confirmed pasted, not just transcribed. In a Debug build the
first 30 level samples of a session also go to stderr, which is how the meter's
range was checked without a human at the microphone.

What an unattended run cannot exercise: granting or revoking Microphone, Input
Monitoring and Accessibility. All three were already granted for this build on
this Mac, so the denied-path notices (and their System Settings buttons) are
written and compiled but have not been seen on screen.
