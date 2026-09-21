import Foundation
import VesperEngine

/// Everything the user can change that has to survive a relaunch, in
/// `UserDefaults`. There is no settings UI yet: these values are written by
/// code (and by the hotkey picker later), and read by the engine at the start
/// of every dictation.
///
/// The hotkey trigger is stored by the engine's own `HotkeyTrigger.load/save`,
/// so the app does not invent a second encoding of the same value.
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let cleanSpeech = "com.vesper.rules.cleanSpeech"
        static let contractions = "com.vesper.rules.contractions"
        static let numbers = "com.vesper.rules.numbers"
        static let currency = "com.vesper.rules.currency"
        static let spokenPunctuation = "com.vesper.rules.spokenPunctuation"
        static let endPunctuation = "com.vesper.rules.endPunctuation"
        static let developerMode = "com.vesper.developerMode"
        static let enabledPacks = "com.vesper.enabledPacks"
        static let playSounds = "com.vesper.playSounds"
        static let showMenuBarIcon = "com.vesper.showMenuBarIcon"
        static let hideDockIcon = "com.vesper.hideDockIcon"
        static let retentionDays = "com.vesper.retentionDays"
        static let meetingDisclosureShown = "com.vesper.meetingDisclosureShown"
        static let labelSpeakers = "com.vesper.labelSpeakers"
        static let noteHotkeyTrigger = "com.vesper.noteHotkeyTrigger"
        static let onboardingCompleted = "com.vesper.onboardingCompleted"
        static let onboardingStep = "com.vesper.onboardingStep"
        static let trialStartedAt = "com.vesper.trialStartedAt"
        static let language = "com.vesper.language"
        static let multilingual = "com.vesper.multilingual"
        static let updateSnoozeUntil = "com.vesper.updateSnoozeUntil"
    }

    /// Closures the Dictionary settings screen uses to read and edit the
    /// engine's `UserDictionaryStore`, wired by `AppDelegate` once the engine
    /// exists (the app builds `AppSettings` before the engine, so this can't
    /// be a constructor argument). `nil` only for the brief window before
    /// that wiring runs.
    struct DictionaryActions {
        var terms: () -> [DictionaryTerm]
        var add: (DictionaryTerm) throws -> Void
        var remove: (String) throws -> Void
    }
    var dictionaryActions: DictionaryActions?

    /// Settings > About/General's "Run setup" button. Wired by `AppDelegate`
    /// to `OnboardingCoordinator.restart()`.
    var runSetupAgainRequest: (() -> Void)?

    /// Settings > About's "Check" pill. Wired by `AppDelegate` to
    /// `UpdateController.checkForUpdates()`; nil only in the brief window
    /// before that wiring runs, and in `--demo` screenshot runs.
    var checkForUpdatesRequest: (() -> Void)?

    /// The speaker labels add-on's install state, for Settings > Models.
    /// Wired by `AppDelegate` to the engine's `SpeakerModelManager` once it
    /// exists.
    @Published var speakerModelStatus: SpeakerModelStatus = .notDownloaded
    /// Settings > Models' toggle turning on: the only place a download ever
    /// starts.
    var downloadSpeakerModelRequest: (() -> Void)?
    /// Settings > Models' "Cancel" button while downloading.
    var cancelSpeakerModelDownloadRequest: (() -> Void)?
    /// Settings > Models' "Remove" button, after its confirm step.
    var removeSpeakerModelRequest: (() -> Void)?

    private let defaults: UserDefaults

    @Published var hotkeyTrigger: HotkeyTrigger {
        didSet { hotkeyTrigger.save(to: defaults) }
    }

    @Published var rules: RulesConfig {
        didSet { saveRules() }
    }

    @Published var developerMode: DeveloperMode {
        didSet { defaults.set(developerMode.rawValue, forKey: Key.developerMode) }
    }

    /// Starter packs that feed the boost candidate pool. Default is the
    /// developer set until onboarding sets it from the user's answer.
    static let defaultPacks: Set<String> = ["devtools", "languages", "cloud", "aws", "ai", "formats", "apps", "golang", "magento"]
    static let allPacks: [String] = ["ai", "apps", "aws", "cloud", "design", "devtools", "education", "finance", "formats", "golang", "languages", "legal", "magento", "marketing", "medical", "product", "sales", "science", "video", "workplace", "writing"]

    @Published var enabledPacks: Set<String> {
        didSet { defaults.set(Array(enabledPacks).sorted(), forKey: Key.enabledPacks) }
    }

    /// A short tone through `Sounds` when a dictation, note or meeting
    /// recording starts and finishes.
    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Key.playSounds) }
    }

    /// Drives the menu bar `NSStatusItem`'s visibility (`AppDelegate`).
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) }
    }

    /// Drives `AppDelegate`'s `NSApp.setActivationPolicy`: true (the
    /// default) keeps Zumbo out of the Dock, false shows it in the Dock and
    /// the app switcher. `LSUIElement` in the Info.plist always starts the
    /// app hidden; this only switches it to `.regular` when the user turns
    /// the setting off.
    @Published var hideDockIcon: Bool {
        didSet { defaults.set(hideDockIcon, forKey: Key.hideDockIcon) }
    }

    /// Whether Zumbo is registered as a login item through
    /// `SMAppService.mainApp`. The OS is the source of truth (no
    /// `UserDefaults` key of our own): `init` seeds this from
    /// `LaunchAtLogin.isEnabled` and every toggle here calls through to
    /// `LaunchAtLogin.set`, so this can never drift from what System
    /// Settings actually has registered.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            let succeeded = LaunchAtLogin.set(launchAtLogin)
            launchAtLoginNeedsApproval = launchAtLogin && (!succeeded || LaunchAtLogin.requiresApproval)
        }
    }
    /// True when the registration needs the user to flip it on in System
    /// Settings > General > Login Items (macOS holds registration in
    /// `.requiresApproval` until they do). The General settings row swaps
    /// its toggle for an "Open Settings" button while this is true.
    @Published var launchAtLoginNeedsApproval: Bool = false

    /// How long a plain dictation stays in history: 7, 30, 90 days, or 0 for
    /// forever. Favorites, notes and meetings are always kept regardless.
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// Shown once, the first time meeting mode is turned on; remembered so it
    /// never shows again.
    @Published var meetingDisclosureShown: Bool {
        didSet { defaults.set(meetingDisclosureShown, forKey: Key.meetingDisclosureShown) }
    }

    /// Meeting mode > "Label speakers": every voice gets a "Speaker N" label.
    /// Its real meaning is "add-on installed and enabled" - Settings >
    /// Models' toggle sets this true when it starts a download, so once the
    /// install finishes the feature is already on. Default off: nothing is
    /// installed until the user asks for it.
    @Published var labelSpeakers: Bool {
        didSet { defaults.set(labelSpeakers, forKey: Key.labelSpeakers) }
    }

    /// A second, optional hotkey that always starts a note (never pastes),
    /// independent of the main dictate trigger. Nil = off. Not stored through
    /// `HotkeyTrigger.save(to:)`, which always writes the same fixed key: this
    /// needs its own `UserDefaults` key, so it is encoded by hand.
    @Published var noteHotkeyTrigger: HotkeyTrigger? {
        didSet { saveNoteHotkeyTrigger() }
    }

    /// False until the seven-step walkthrough finishes (or its last step is
    /// skipped). Settings > About's "Run setup" flips it back to false and
    /// restarts it. The DEBUG build also treats `--onboarding` as "show it
    /// regardless".
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    /// The step onboarding was on when the app last quit mid-walkthrough
    /// (0 = no saved step). Written on every step change, cleared once
    /// onboarding finishes, so a "Quit & Reopen" from a permission's system
    /// dialog - which a menu-bar app with no Dock icon does not survive -
    /// resumes where the owner left off instead of restarting from Welcome.
    @Published var onboardingStep: Int {
        didSet { defaults.set(onboardingStep, forKey: Key.onboardingStep) }
    }

    /// When the 3-day trial started, set by onboarding's last step ("Start
    /// your 3-day trial"), not silently at first launch. `UserDefaults` for
    /// now; the License work moves this to the Keychain so it survives a
    /// reinstall, which is the point of gating on it at all.
    @Published var trialStartedAt: Date? {
        didSet {
            if let trialStartedAt {
                defaults.set(trialStartedAt.timeIntervalSince1970, forKey: Key.trialStartedAt)
            } else {
                defaults.removeObject(forKey: Key.trialStartedAt)
            }
        }
    }

    /// The ISO code (e.g. "en") the engine's v3 joint decoder filters
    /// generated tokens to, so English never comes out as Cyrillic and vice
    /// versa. English by default - launch is English-only marketing.
    /// `VesperEngine.DictationLanguageOption.menuOptions` lists every value
    /// this can hold; `DictationSession.setLanguage` maps it to FluidAudio's
    /// `Language`, keeping that type out of the app target.
    @Published var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }

    /// "I also dictate in other languages": when true the engine gets no
    /// language hint at all (auto, per-sentence detection) and `language`
    /// above is ignored. Off by default - most people dictate in one
    /// language and get the accuracy boost from day one.
    @Published var multilingual: Bool {
        didSet { defaults.set(multilingual, forKey: Key.multilingual) }
    }

    /// When the update notice's "Later" pill was last pressed, plus 24
    /// hours. Background checks stay silent until then; a manual check from
    /// Settings > About ignores it, because the owner asked for that one.
    /// Nil means "never snoozed".
    @Published var updateSnoozeUntil: Date? {
        didSet {
            if let updateSnoozeUntil {
                defaults.set(updateSnoozeUntil.timeIntervalSince1970, forKey: Key.updateSnoozeUntil)
            } else {
                defaults.removeObject(forKey: Key.updateSnoozeUntil)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.hotkeyTrigger = HotkeyTrigger.load(from: defaults)

        let fallback = RulesConfig()
        func flag(_ key: String, _ fallbackValue: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallbackValue
        }
        self.rules = RulesConfig(
            cleanSpeech: flag(Key.cleanSpeech, fallback.cleanSpeech),
            contractions: flag(Key.contractions, fallback.contractions),
            numbers: flag(Key.numbers, fallback.numbers),
            currency: flag(Key.currency, fallback.currency),
            spokenPunctuation: flag(Key.spokenPunctuation, fallback.spokenPunctuation),
            endPunctuation: flag(Key.endPunctuation, fallback.endPunctuation)
        )

        let raw = defaults.string(forKey: Key.developerMode) ?? DeveloperMode.auto.rawValue
        self.developerMode = DeveloperMode(rawValue: raw) ?? .auto

        if let stored = defaults.stringArray(forKey: Key.enabledPacks) {
            self.enabledPacks = Set(stored)
        } else {
            self.enabledPacks = AppSettings.defaultPacks
        }

        self.playSounds = defaults.object(forKey: Key.playSounds) as? Bool ?? true
        self.showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        self.hideDockIcon = defaults.object(forKey: Key.hideDockIcon) as? Bool ?? true

        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.launchAtLoginNeedsApproval = LaunchAtLogin.requiresApproval

        let storedRetention = defaults.object(forKey: Key.retentionDays) as? Int
        self.retentionDays = storedRetention ?? 30
        self.meetingDisclosureShown = defaults.object(forKey: Key.meetingDisclosureShown) as? Bool ?? false
        self.labelSpeakers = defaults.object(forKey: Key.labelSpeakers) as? Bool ?? false
        self.noteHotkeyTrigger = AppSettings.loadNoteHotkeyTrigger(from: defaults)

        self.onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
        self.onboardingStep = defaults.object(forKey: Key.onboardingStep) as? Int ?? 0
        if let stored = defaults.object(forKey: Key.trialStartedAt) as? Double {
            self.trialStartedAt = Date(timeIntervalSince1970: stored)
        } else {
            self.trialStartedAt = nil
        }

        self.language = defaults.string(forKey: Key.language) ?? "en"
        self.multilingual = defaults.object(forKey: Key.multilingual) as? Bool ?? false
        if let stored = defaults.object(forKey: Key.updateSnoozeUntil) as? Double {
            self.updateSnoozeUntil = Date(timeIntervalSince1970: stored)
        } else {
            self.updateSnoozeUntil = nil
        }
    }

    private func saveNoteHotkeyTrigger() {
        guard let noteHotkeyTrigger else {
            defaults.removeObject(forKey: Key.noteHotkeyTrigger)
            return
        }
        guard let data = try? JSONEncoder().encode(noteHotkeyTrigger) else { return }
        defaults.set(data, forKey: Key.noteHotkeyTrigger)
    }

    private static func loadNoteHotkeyTrigger(from defaults: UserDefaults) -> HotkeyTrigger? {
        guard let data = defaults.data(forKey: Key.noteHotkeyTrigger),
              let trigger = try? JSONDecoder().decode(HotkeyTrigger.self, from: data)
        else { return nil }
        return trigger
    }

    /// How many rule groups are on, for the Rules tab count.
    var enabledRuleCount: Int {
        [rules.cleanSpeech, rules.contractions, rules.numbers, rules.currency, rules.spokenPunctuation, rules.endPunctuation]
            .filter { $0 }.count
    }

    private func saveRules() {
        defaults.set(rules.cleanSpeech, forKey: Key.cleanSpeech)
        defaults.set(rules.contractions, forKey: Key.contractions)
        defaults.set(rules.numbers, forKey: Key.numbers)
        defaults.set(rules.currency, forKey: Key.currency)
        defaults.set(rules.spokenPunctuation, forKey: Key.spokenPunctuation)
        defaults.set(rules.endPunctuation, forKey: Key.endPunctuation)
    }
}
