import Foundation

/// The three-state mark used on every onboarding step that asks for
/// something (a permission, a hotkey press, a try-it result): grey before
/// it was asked, green once granted/done, red if it was asked and refused.
/// Steps 4 and 6 never reach `.denied` - there is nothing to deny, only
/// "not yet" and "done" - but the same visual language applies.
enum OnboardingMarkState {
    case notAsked
    case granted
    case denied
}

/// "What you dictate most" tiles (step 5). Order matches the brief. Maps to
/// starter packs (NOTES.md "Onboarding step 5") and to one generic,
/// example-free sentence about what changes for that area (NOTES.md
/// "Onboarding copy correction").
enum OnboardingArea: String, CaseIterable, Identifiable {
    case developers
    case design
    case team
    case marketing
    case legal
    case medical
    case writing
    case video

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developers: return "Coding agents and code"
        case .design: return "Design"
        case .team: return "Team messages and docs"
        case .marketing: return "Marketing and sales"
        case .legal: return "Legal and contracts"
        case .medical: return "Medical notes"
        case .writing: return "Writing and research"
        case .video: return "Video and audio"
        }
    }

    /// Starter packs this area turns on (`AppSettings.allPacks` ids).
    var packs: [String] {
        switch self {
        case .developers: return ["devtools", "languages", "ai", "cloud", "aws", "formats"]
        case .design: return ["design", "apps", "formats"]
        case .team: return ["workplace", "apps", "product", "formats"]
        case .marketing: return ["marketing", "sales", "finance", "apps"]
        case .legal: return ["legal", "finance", "workplace"]
        case .medical: return ["medical", "science"]
        case .writing: return ["writing", "science", "education", "apps"]
        case .video: return ["video", "apps"]
        }
    }

    /// One generic sentence, no example terms (NOTES.md "Onboarding copy
    /// correction" replaced the earlier pack-term-name version of this).
    var line: String {
        switch self {
        case .developers: return "Knows developer tools, commands and technical names."
        case .design: return "Knows design tools, file formats and layout terms."
        case .team: return "Knows workplace tools and product terms."
        case .marketing: return "Knows campaign, channel and analytics vocabulary."
        case .legal: return "Knows contract and court terms."
        case .medical: return "Knows clinical terms and drug names."
        case .writing: return "Knows publishing and research terms."
        case .video: return "Knows editing tools and formats."
        }
    }

    /// Shown once, under the tiles, regardless of which areas are picked.
    /// Notes and meeting mode are core features, sold here rather than
    /// tucked into one throwaway line.
    static let notesLine = "Notes: dictate straight into Zumbo, nothing pasted, everything searchable."
    static let meetingLine = "Meeting mode: records a meeting through the microphone and labels each speaker. Nothing leaves this Mac."
}

/// Step 7's one-time price, in one place so the Worker's spots-left counter
/// can drive `launchSpots` (and eventually `launchPriceCents`) once the
/// licensing backend exists (NOTES.md "Licensing backend"). Static for now.
enum OnboardingPricing {
    static let launchPriceCents = 900
    static let launchSpots = 10
    static let regularPriceCents = 1500

    static var launchPriceLabel: String { "$\(launchPriceCents / 100)" }
    static var regularPriceLabel: String { "$\(regularPriceCents / 100)" }
    static var priceLine: String {
        "\(launchPriceLabel) for the first \(launchSpots) buyers, then \(regularPriceLabel). One-time, not a subscription. Yours for good."
    }
}
