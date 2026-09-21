import AppKit
import SwiftUI

/// Settings > Feedback: one card, three states (Praise/Problem/Feature
/// request), sent to the same Worker as licensing
/// (`LicenseEndpoints.production.baseURL/feedback`, see
/// zumbo-api/src/routes/feedback.ts). Only app version, macOS version and
/// license state ride along - no telemetry, no identifiers.
struct FeedbackSettingsView: View {
    @ObservedObject var licenseState: LicenseState

    enum Kind: String, CaseIterable {
        case praise = "Praise"
        case problem = "Problem"
        case feature = "Feature request"

        var wireValue: String {
            switch self {
            case .praise: return "praise"
            case .problem: return "problem"
            case .feature: return "feature"
            }
        }

        var placeholder: String {
            switch self {
            case .praise: return "What do you like? We may quote you if you allow it below."
            case .problem: return "What happened, and what did you expect?"
            case .feature: return "What should Zumbo do?"
            }
        }
    }

    private static let maxLength = 4000

    @State private var kind: Kind = .praise
    @State private var text: String = ""
    @State private var email: String = ""
    @State private var mayQuote = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var showThankYou = false
    @FocusState private var textFocused: Bool

    private let client = FeedbackClient()

    private var overLimit: Bool { text.count > Self.maxLength }
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !overLimit && !isSending
    }
    private var emailLooksValid: Bool {
        email.isEmpty || (email.contains("@") && email.split(separator: "@").count == 2
            && (email.split(separator: "@").last?.contains(".") ?? false))
    }

    var body: some View {
        SettingsCard(title: "Send feedback") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What is this about?")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.92))
                    SettingsSegmented(
                        options: Kind.allCases.map { (value: $0, label: $0.rawValue) },
                        selection: $kind)
                    .onChange(of: kind) { _, newValue in
                        if newValue != .praise { mayQuote = false }
                    }
                }

                textArea
                SettingsDivider()
                emailRow
                if kind == .praise {
                    SettingsDivider()
                    quoteRow
                }
                SettingsDivider()
                sendRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Text area

    private var textArea: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                SelectableTextView(
                    text: $text,
                    onSelectionChange: { _, _, _ in },
                    onScroll: {}
                )
                .focused($textFocused)
                if text.isEmpty {
                    Text(kind.placeholder)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.top, 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 100)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onTapGesture { textFocused = true }

            Text("\(text.count) / \(Self.maxLength)")
                .font(.system(size: 10))
                .foregroundStyle(overLimit ? Color(red: 0.95, green: 0.35, blue: 0.32) : Color.white.opacity(0.4))
        }
    }

    // MARK: - Email

    private var emailRow: some View {
        SettingsRow(label: "Your email (optional)", description: "Only if you want a reply.") {
            TextField("you@example.com", text: $email)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
                .frame(width: 200)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            emailLooksValid ? Color.white.opacity(0.08) : Color(red: 0.95, green: 0.35, blue: 0.32).opacity(0.6),
                            lineWidth: 1)
                )
                .pointer()
        }
    }

    // MARK: - Quote

    private var quoteRow: some View {
        SettingsRow(label: "You may quote me", description: "Lets us use your words on the website, first name only.") {
            PillToggle(isOn: $mayQuote)
        }
    }

    // MARK: - Send

    private var sendRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Sent with your app version and macOS version. Nothing else.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 10)
                sendButton
            }
            if let sendError {
                Text(sendError)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
            }
            if showThankYou {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(SettingsTheme.accent)
                    Text("Thank you. We read every message.")
                        .foregroundStyle(SettingsTheme.accent)
                }
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private var sendButton: some View {
        Button {
            Task { await send() }
        } label: {
            HStack(spacing: 6) {
                if isSending {
                    ProgressView().controlSize(.small).tint(.black)
                }
                Text("Send")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(canSend ? Color.black : Color.white.opacity(0.4))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(canSend ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointer()
        .disabled(!canSend)
        .hoverTip("Sends this to the Zumbo team")
    }

    // MARK: - Networking

    private func send() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !overLimit else { return }
        isSending = true
        sendError = nil
        showThankYou = false
        defer { isSending = false }

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let submission = FeedbackSubmission(
            kind: kind.wireValue,
            text: text,
            email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : email.trimmingCharacters(in: .whitespacesAndNewlines),
            mayQuote: kind == .praise && mayQuote,
            appVersion: appVersion,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            licenseState: licenseStateWireValue)

        do {
            try await client.send(submission)
            text = ""
            email = ""
            mayQuote = false
            kind = .praise
            withAnimation(.easeOut(duration: 0.15)) { showThankYou = true }
            Task {
                try? await Task.sleep(for: .seconds(6))
                withAnimation(.easeOut(duration: 0.2)) { showThankYou = false }
            }
        } catch let error as FeedbackClientError {
            sendError = error.message
        } catch {
            sendError = FeedbackClientError.network.message
        }
    }

    private var licenseStateWireValue: String {
        switch licenseState.status {
        case .trial: return "trial"
        case .trialEnded: return "trialEnded"
        case .licensed: return "licensed"
        case .unlicensed: return "unlicensed"
        }
    }
}
