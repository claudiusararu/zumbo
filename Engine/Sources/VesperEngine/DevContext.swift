import Foundation

/// Developer mode setting, per NOTES.md: "Auto / Always / Off, Auto default."
public enum DeveloperMode: String, Codable, Sendable {
    case auto
    case always
    case off
}

/// The gate's verdict for one dictation: whether to run vocabulary boosting
/// and dev-only rules, plus the score and a human-readable reason (useful in
/// a debug/settings view, and in `zumbo-cli transcribe` output).
public struct DevContextDecision: Equatable, Sendable {
    public let shouldBoost: Bool
    public let score: Double
    public let reason: String

    public init(shouldBoost: Bool, score: Double, reason: String) {
        self.shouldBoost = shouldBoost
        self.score = score
        self.reason = reason
    }
}

/// Topic gating, per NOTES.md ("Context gating"): TOPIC decides, not the app.
/// Score = developer-word count in the plain transcript + dictionary hits +
/// a decayed memory of the last 5 dictations' scores, so one off-topic
/// sentence does not immediately flip a dev-mode session back to general.
/// The frontmost app is only a small tie-breaker bonus, never the decider.
public final class DevContextGate {
    public var mode: DeveloperMode
    public let threshold: Double

    private let devWordSet: Set<String>
    private var history: [Double] = []
    private static let historyLimit = 5
    private static let historyDecay = 0.6

    /// Bundle ids that nudge the score when they're frontmost - a tie-breaker
    /// only, per NOTES.md, never sufficient on their own to cross `threshold`.
    public static let devBundleBonus: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
        "app.zed.Zed",
        "com.openai.chat",
    ]
    private static let bundleBonusScore = 0.5

    public init(
        mode: DeveloperMode = .auto,
        devWords: [String] = DevContextGate.defaultDevWords,
        threshold: Double = 1.0
    ) {
        self.mode = mode
        self.devWordSet = Set(devWords.map { $0.lowercased() })
        self.threshold = threshold
    }

    /// - Parameters:
    ///   - transcript: the plain (pre-boosting) transcript for this dictation.
    ///   - dictionaryHits: how many user/starter dictionary terms already
    ///     appear in the plain transcript (a strong dev-topic signal on its own).
    ///   - frontmostBundleID: the frontmost app's bundle id, tie-breaker only.
    public func evaluate(
        transcript: String,
        dictionaryHits: Int = 0,
        frontmostBundleID: String? = nil
    ) -> DevContextDecision {
        switch mode {
        case .always:
            return DevContextDecision(shouldBoost: true, score: .infinity, reason: "mode=always")
        case .off:
            return DevContextDecision(shouldBoost: false, score: 0, reason: "mode=off")
        case .auto:
            let devWordCount = Self.tokenize(transcript).filter { devWordSet.contains($0) }.count
            let dictionaryScore = Double(dictionaryHits) * 1.5
            let memoryScore = decayedMemoryScore()
            var score = Double(devWordCount) + dictionaryScore + memoryScore
            var reason = "auto: \(devWordCount) dev word(s) + \(String(format: "%.1f", dictionaryScore)) dict"
                + " + \(String(format: "%.1f", memoryScore)) memory"
            if let frontmostBundleID, Self.devBundleBonus.contains(frontmostBundleID) {
                score += Self.bundleBonusScore
                reason += " + \(Self.bundleBonusScore) app bonus"
            }
            reason += " = \(String(format: "%.1f", score)) vs threshold \(threshold)"
            recordHistory(Double(devWordCount) + dictionaryScore)
            return DevContextDecision(shouldBoost: score >= threshold, score: score, reason: reason)
        }
    }

    /// Resets the rolling memory of recent dictations (e.g. when the user
    /// goes idle, per NOTES.md: "stays dev until speech drifts away ... or
    /// the user idles").
    public func resetMemory() {
        history.removeAll()
    }

    private func decayedMemoryScore() -> Double {
        var total = 0.0
        var weight = Self.historyDecay
        for score in history.reversed() {
            total += score * weight
            weight *= Self.historyDecay
        }
        return total
    }

    private func recordHistory(_ score: Double) {
        history.append(score)
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "#" }.map(String.init)
    }

    /// ~150 words a developer's dictation is likely to contain, per NOTES.md's
    /// "Primary signal ... developer words (deploy, commit, function, config,
    /// endpoint)". Deliberately generic engineering vocabulary, not tied to any
    /// one stack, since the dictionary layer already covers specific tools/terms.
    public static let defaultDevWords: [String] = [
        "deploy", "deployment", "commit", "commits", "branch", "merge", "rebase", "checkout",
        "function", "method", "class", "struct", "interface", "protocol", "enum", "variable",
        "constant", "parameter", "argument", "return", "array", "dictionary", "string", "boolean",
        "integer", "float", "null", "nil", "undefined", "pointer", "reference", "config",
        "configuration", "endpoint", "api", "rest", "graphql", "webhook", "websocket", "server",
        "client", "database", "query", "schema", "migration", "index", "table", "row", "column",
        "cache", "queue", "thread", "process", "async", "await", "callback", "promise", "closure",
        "compile", "compiler", "build", "debug", "debugger", "breakpoint", "exception", "error",
        "stacktrace", "log", "logging", "terminal", "shell", "bash", "zsh", "console", "repository",
        "repo", "package", "dependency", "dependencies", "module", "import", "export", "namespace",
        "framework", "library", "sdk", "cli", "ide", "compiler", "runtime", "syntax", "parser",
        "token", "regex", "json", "yaml", "xml", "http", "https", "url", "uri", "localhost", "port",
        "firewall", "proxy", "dns", "ssl", "tls", "certificate", "oauth", "jwt", "authentication",
        "authorization", "encryption", "hash", "algorithm", "recursion", "iteration", "loop",
        "refactor", "refactoring", "optimize", "latency", "throughput", "bandwidth", "scalability",
        "microservice", "monolith", "middleware", "container", "docker", "kubernetes", "pod",
        "cluster", "namespace", "ingress", "loadbalancer", "terraform", "ansible", "pipeline", "ci",
        "cd", "unittest", "integrationtest", "testsuite", "assertion", "mock", "stub", "linter",
        "formatter", "typescript", "javascript", "python", "swift", "swiftui", "kotlin", "rust",
        "golang", "ruby", "php", "sql", "nosql", "redis", "postgres", "postgresql", "mysql",
        "mongodb", "sqlite", "npm", "yarn", "pnpm", "pip", "cargo", "xcode", "vscode", "github",
        "gitlab", "bitbucket", "pullrequest", "pr", "issue", "ticket", "sprint", "standup",
        "backlog", "changelog", "versioning", "semver", "release", "staging", "production",
        "environment", "env", "secrets", "token", "session", "middleware", "route", "router",
    ]
}
