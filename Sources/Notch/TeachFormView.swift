import SwiftUI

/// The Teach form that takes the place of the detail panel's text editor
/// while a correction is being made. Self-contained on purpose (no app
/// types beyond SwiftUI), so it can be rendered headless for a visual check.
///
/// Layout, two columns inside one lighter card so it reads as a different
/// layer from the black panel: left is what was heard and the fix, right is
/// the three actions, each with a plain-words line on what it does.
struct TeachFormView: View {
    let heard: String
    let accent: Color
    let reduceMotion: Bool
    let onReplaceHere: (String) -> Void
    let onReplaceEverywhere: (String) -> Void
    let onReplaceAndTeach: (String, Bool) -> Void
    let onClose: () -> Void

    @State private var shouldBe: String = ""
    @State private var addToMyWords = true
    @FocusState private var fieldFocused: Bool

    private var unchanged: Bool {
        shouldBe.trimmingCharacters(in: .whitespacesAndNewlines) == heard
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Teach Zumbo this word")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                        Text("Back to the text")
                            .font(.system(size: 10.5, weight: .medium))
                            .fixedSize()
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.12), in: Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .pointer()
                .accessibilityLabel("Back to the text")
            }

            HStack(alignment: .top, spacing: 16) {
                labeled("Heard as") {
                    Text(heard)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                labeled("Should be") {
                    TextField("", text: $shouldBe)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(fieldFocused ? accent.opacity(0.9) : Color.white.opacity(0.14), lineWidth: 1))
                        .focused($fieldFocused)
                        .onSubmit { primaryAction() }
                }
            }

            checkboxRow

            Spacer(minLength: 0)

            Text(unchanged
                 ? "Type the correct spelling under Should be to replace it, or just teach the word as it is."
                 : "Here changes this one spot. Everywhere changes every place in this note. Teach also remembers it for next time.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                pill("Replace here", filled: false, disabled: unchanged) { onReplaceHere(shouldBe) }
                pill("Replace everywhere", filled: false, disabled: unchanged) { onReplaceEverywhere(shouldBe) }
                pill(unchanged ? "Teach it" : "Replace everywhere and teach", filled: true, disabled: false) { primaryAction() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .onAppear {
            shouldBe = heard
            Task {
                try? await Task.sleep(for: .milliseconds(60))
                fieldFocused = true
            }
        }
        .onExitCommand { onClose() }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func primaryAction() {
        onReplaceAndTeach(shouldBe, addToMyWords)
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            content()
        }
    }

    private var checkboxRow: some View {
        Button {
            addToMyWords.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: addToMyWords ? "checkmark.square.fill" : "square")
                    .font(.system(size: 14))
                    .foregroundStyle(addToMyWords ? accent : Color.white.opacity(0.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to My words")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white)
                    Text("Zumbo will recognise it next time you say it.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .pointer()
    }

    /// Same pill buttons as the rest of the app: white filled for the main
    /// action, translucent white for the others, short label only.
    private func pill(_ title: String, filled: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
                .foregroundStyle(filled ? Color.black : Color.white.opacity(disabled ? 0.4 : 0.95))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(filled ? Color.white : Color.white.opacity(disabled ? 0.06 : 0.14)))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(filled ? .defaultAction : nil)
        .pointer()
    }
}

