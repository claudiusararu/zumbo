import FluidAudio

/// English display names and menu ordering for FluidAudio's `Language`
/// (`Shared/TokenLanguageFilter.swift`), for Settings' and onboarding's
/// "Main language" menu. FluidAudio ships the ISO codes only.
extension Language {
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .dutch: return "Dutch"
        case .danish: return "Danish"
        case .swedish: return "Swedish"
        case .finnish: return "Finnish"
        case .hungarian: return "Hungarian"
        case .estonian: return "Estonian"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .maltese: return "Maltese"
        case .polish: return "Polish"
        case .czech: return "Czech"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .croatian: return "Croatian"
        case .bosnian: return "Bosnian"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .belarusian: return "Belarusian"
        case .bulgarian: return "Bulgarian"
        case .serbian: return "Serbian"
        case .greek: return "Greek"
        }
    }

    /// Every language the v3 joint decoder can filter to, English first,
    /// then the rest alphabetical by `displayName` - the exact order
    /// Settings' and onboarding's "Main language" menu list them in.
    public static let menuOrder: [Language] = {
        let rest = allCases.filter { $0 != .english }.sorted { $0.displayName < $1.displayName }
        return [.english] + rest
    }()

    /// Maps `AppSettings.language`'s persisted ISO code to a hint. An
    /// unrecognized code (a future FluidAudio removal, a corrupted default)
    /// falls back to English rather than crashing or silently going auto -
    /// `AppSettings.language`'s own default is `"en"`.
    public static func forSettingsCode(_ code: String) -> Language {
        Language(rawValue: code) ?? .english
    }
}

/// One entry in the "Main language" menu: an ISO code (what
/// `AppSettings.language` persists) plus its English display name. A plain
/// struct, not FluidAudio's `Language` itself, so the app target (which
/// links `VesperEngine` only, not `FluidAudio` directly) can build the menu
/// without importing FluidAudio.
public struct DictationLanguageOption: Identifiable, Sendable {
    public let code: String
    public let displayName: String
    public var id: String { code }
}

extension DictationLanguageOption {
    /// English first, then the rest alphabetical by display name - see
    /// `Language.menuOrder`.
    public static let menuOptions: [DictationLanguageOption] =
        Language.menuOrder.map { DictationLanguageOption(code: $0.rawValue, displayName: $0.displayName) }
}
