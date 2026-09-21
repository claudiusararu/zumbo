import Foundation

/// Static metadata for the Dictionary > Packs grid in Settings: a display
/// name, a "who it's for plus examples" description, a term count and a
/// dozen sample terms (for the tile's hover tooltip) per pack in
/// `AppSettings.allPacks`.
///
/// The counts and sample terms are not computed at runtime: the starter
/// vocabulary JSON lives in the `VesperEngine` package target and is not
/// exposed to the app target as a countable resource. To regenerate this
/// table after editing `seeds/packs/*.json`, run from the repo root:
///
///     python3 -c "
///     import json, glob, os
///     for f in sorted(glob.glob('seeds/packs/*.json')):
///         name = os.path.basename(f)[:-5]
///         d = json.load(open(f))
///         terms = [t['text'] for t in d['terms']]
///         print(name, len(terms), terms[:12])
///     "
///
/// and update `PackCatalog.all` below: the count, the sample terms, and the
/// "and N more" tail of the description (N = count minus however many
/// examples the description names).
enum PackCatalog {

    struct Pack {
        let id: String
        let displayName: String
        /// Who the pack is for, plus a few real examples and how many more
        /// terms it carries, e.g. "For people who ship code: GitHub,
        /// Docker, Kubernetes, kubectl, npm, tsconfig and 167 more."
        let description: String
        let termCount: Int
        /// A dozen real terms from the pack, for the tile's hover tooltip.
        let sampleTerms: [String]
    }

    /// Order matches `AppSettings.allPacks`.
    static let all: [Pack] = [
        Pack(
            id: "ai", displayName: "AI",
            description: "For people building with AI models: OpenAI, Anthropic, Claude, ChatGPT, LangChain and 38 more.",
            termCount: 43,
            sampleTerms: ["OpenAI", "Anthropic", "Claude", "Claude Code", "ChatGPT", "GPT", "Codex", "Copilot", "Gemini", "Llama", "Mistral", "DeepSeek"]),
        Pack(
            id: "apps", displayName: "Apps",
            description: "For people who live in everyday software: Notion, Slack, Figma, Zoom, Google Drive and 145 more.",
            termCount: 150,
            sampleTerms: ["Notion", "Obsidian", "Roam", "Logseq", "Evernote", "Apple Notes", "Bear", "Craft", "Ulysses", "iA Writer", "Todoist", "Things"]),
        Pack(
            id: "aws", displayName: "AWS",
            description: "For people who run infrastructure on AWS: EC2, S3, Lambda, DynamoDB, CloudFront and 55 more.",
            termCount: 60,
            sampleTerms: ["AWS", "Amazon Web Services", "EC2", "S3", "Lambda", "DynamoDB", "RDS", "Aurora", "CloudFront", "CloudWatch", "CloudFormation", "IAM"]),
        Pack(
            id: "cloud", displayName: "Cloud",
            description: "For people on other clouds and platforms: Azure, Google Cloud, Cloudflare, Vercel, Terraform and 57 more.",
            termCount: 62,
            sampleTerms: ["Azure", "Azure DevOps", "Azure Functions", "Cosmos DB", "Blob Storage", "Entra ID", "Google Cloud", "GCP", "Cloud Run", "Cloud Functions", "BigQuery", "Firestore"]),
        Pack(
            id: "design", displayName: "Design",
            description: "For people who design interfaces: Figma, Sketch, Framer, design tokens, auto layout and 90 more.",
            termCount: 95,
            sampleTerms: ["Figma", "FigJam", "Sketch", "Framer", "Webflow", "Photoshop", "Illustrator", "Adobe XD", "InDesign", "Affinity Designer", "Affinity Photo", "Affinity Publisher"]),
        Pack(
            id: "devtools", displayName: "Devtools",
            description: "For people who ship code: GitHub, Docker, Kubernetes, kubectl, npm, tsconfig and 167 more.",
            termCount: 173,
            sampleTerms: ["GitHub", "GitHub Actions", "GitLab", "Bitbucket", "Jira", "Confluence", "Linear", "Jenkins", "CircleCI", "Travis CI", "Postman", "Insomnia"]),
        Pack(
            id: "education", displayName: "Education",
            description: "For people who teach or study: Canvas, Blackboard, Moodle, syllabus, GPA and 80 more.",
            termCount: 85,
            sampleTerms: ["Canvas", "Blackboard", "Moodle", "Google Classroom", "Khan Academy", "Coursera", "Udemy", "edX", "Duolingo", "Quizlet", "Anki", "Kahoot"]),
        Pack(
            id: "finance", displayName: "Finance",
            description: "For people who watch the numbers: ARR, MRR, EBITDA, cap table, Series A and 101 more.",
            termCount: 106,
            sampleTerms: ["ARR", "MRR", "ARPU", "LTV", "CAC", "churn", "NRR", "EBITDA", "P&L", "COGS", "GAAP", "IFRS"]),
        Pack(
            id: "formats", displayName: "Formats",
            description: "For people who move files around: PDF, DOCX, XLSX, CSV, JSON and 49 more.",
            termCount: 54,
            sampleTerms: ["PDF", "DOCX", "DOC", "XLSX", "PPTX", "CSV", "TSV", "JSON", "YAML", "TOML", "XML", "HTML"]),
        Pack(
            id: "golang", displayName: "Go",
            description: "For Go developers: Golang, goroutines, gofmt, go mod, gRPC, GORM, Cobra and 79 more.",
            termCount: 86,
            sampleTerms: ["Golang", "goroutine", "gofmt", "go mod", "go test", "golangci-lint", "gRPC", "Protobuf", "GORM", "sqlc", "Cobra", "Viper"]),
        Pack(
            id: "languages", displayName: "Languages",
            description: "For people who write code: TypeScript, Python, Swift, SwiftUI, React and 113 more.",
            termCount: 118,
            sampleTerms: ["TypeScript", "JavaScript", "Python", "Swift", "SwiftUI", "Objective-C", "Kotlin", "Java", "Go", "Rust", "C++", "C#"]),
        Pack(
            id: "legal", displayName: "Legal",
            description: "For people who read contracts: NDA, MSA, SOW, GDPR, indemnification and 82 more.",
            termCount: 87,
            sampleTerms: ["NDA", "MSA", "SOW", "DPA", "SLA", "GDPR", "CCPA", "HIPAA", "SOC 2", "ISO 27001", "indemnification", "force majeure"]),
        Pack(
            id: "magento", displayName: "Magento",
            description: "For Magento and Adobe Commerce developers: Hyvä, Luma, bin/magento, di.xml, EAV, PWA Studio and 112 more.",
            termCount: 118,
            sampleTerms: ["Magento 2", "Adobe Commerce", "Mage-OS", "Hyvä", "Hyvä Checkout", "Luma", "PWA Studio", "bin/magento", "setup:upgrade", "di.xml", "EAV", "Amasty"]),
        Pack(
            id: "marketing", displayName: "Marketing",
            description: "For marketers, paid and organic: Ads Manager, ROAS, Performance Max, Klaviyo, AppsFlyer, ABM, creative brief and 322 more.",
            termCount: 329,
            sampleTerms: ["SERP", "backlink", "canonical tag", "hreflang", "schema markup", "Core Web Vitals", "LCP", "CLS", "INP", "Google Search Console", "Ahrefs", "Semrush"]),
        Pack(
            id: "medical", displayName: "Medical",
            description: "For people in clinical settings: BP, HR, SpO2, ECG, ICD-10 and 84 more.",
            termCount: 89,
            sampleTerms: ["BP", "HR", "SpO2", "BMI", "ECG", "EKG", "MRI", "CT", "CBC", "BMP", "A1C", "LDL"]),
        Pack(
            id: "product", displayName: "Product",
            description: "For people who manage the roadmap: PRD, MVP, sprint, backlog, OKR and 75 more.",
            termCount: 80,
            sampleTerms: ["PRD", "MVP", "roadmap", "Productboard", "Aha!", "Linear", "Jira", "sprint", "backlog", "epic", "story points", "retro"]),
        Pack(
            id: "sales", displayName: "Sales",
            description: "For people who work a pipeline: Salesforce, Pipedrive, MEDDIC, quota, ACV and 78 more.",
            termCount: 83,
            sampleTerms: ["Salesforce", "Pipedrive", "Close", "Apollo", "ZoomInfo", "Outreach", "Salesloft", "Gong", "Chorus", "Calendly", "DocuSign", "PandaDoc"]),
        Pack(
            id: "science", displayName: "Science",
            description: "For people doing research: DOI, arXiv, PubMed, p-value, peer review and 81 more.",
            termCount: 86,
            sampleTerms: ["DOI", "arXiv", "PubMed", "Google Scholar", "Zotero", "Mendeley", "LaTeX", "Overleaf", "BibTeX", "Jupyter", "pandas", "NumPy"]),
        Pack(
            id: "video", displayName: "Video",
            description: "For people editing and streaming video: Premiere Pro, Final Cut Pro, DaVinci Resolve, B-roll, OBS and 81 more.",
            termCount: 86,
            sampleTerms: ["Premiere Pro", "Final Cut Pro", "DaVinci Resolve", "After Effects", "CapCut", "Descript", "OBS", "Streamlabs", "Ecamm", "Riverside", "Zencastr", "Loom"]),
        Pack(
            id: "workplace", displayName: "Workplace",
            description: "For people navigating HR and ops: Workday, BambooHR, Gusto, PTO, 1:1 and 79 more.",
            termCount: 84,
            sampleTerms: ["Workday", "BambooHR", "Gusto", "Rippling", "Deel", "Remote.com", "Lattice", "Culture Amp", "15Five", "Greenhouse", "Lever", "Ashby"]),
        Pack(
            id: "writing", displayName: "Writing",
            description: "For people who write for a living: Scrivener, Grammarly, Substack, Oxford comma, em dash and 80 more.",
            termCount: 85,
            sampleTerms: ["Scrivener", "Ulysses", "iA Writer", "Grammarly", "Hemingway App", "Google Docs", "Substack", "Medium", "Ghost", "WordPress", "Kindle Direct Publishing", "ISBN"]),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func pack(for id: String) -> Pack {
        byID[id] ?? Pack(id: id, displayName: id.capitalized, description: "", termCount: 0, sampleTerms: [])
    }
}
