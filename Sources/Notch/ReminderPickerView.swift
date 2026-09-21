import SwiftUI

/// The inline reminder picker that takes the place of the detail panel's text
/// editor while a reminder is being set by hand (entry point B). Same visual
/// language as `TeachFormView`: a lighter card (white 6% surface, 10 pt
/// radius) so it reads as a different layer from the black panel behind it.
/// Self-contained (no app types beyond SwiftUI), so it can be rendered
/// headless for a visual check.
struct ReminderPickerView: View {
    let reference: Date
    let accent: Color
    let reduceMotion: Bool
    /// True once notification permission was asked for and denied: "Set"
    /// would silently do nothing useful, so the picker says so instead and
    /// offers the exact System Settings pane.
    let notificationsDenied: Bool
    let onSet: (Date) -> Void
    let onCancel: () -> Void
    var onOpenSystemSettings: () -> Void = {}

    @State private var selected: Date
    /// Which quick pill (if any) matches `selected` right now - tracked
    /// explicitly rather than by comparing dates, so exactly one pill (or
    /// none, once the date field is edited by hand) ever reads as selected.
    @State private var selectedQuick: Quick?

    init(
        reference: Date = Date(), accent: Color, reduceMotion: Bool, notificationsDenied: Bool = false,
        onSet: @escaping (Date) -> Void, onCancel: @escaping () -> Void,
        onOpenSystemSettings: @escaping () -> Void = {}
    ) {
        self.reference = reference
        self.accent = accent
        self.reduceMotion = reduceMotion
        self.notificationsDenied = notificationsDenied
        self.onSet = onSet
        self.onCancel = onCancel
        self.onOpenSystemSettings = onOpenSystemSettings
        _selected = State(initialValue: Self.quickDate(.inOneHour, reference: reference))
        _selectedQuick = State(initialValue: .inOneHour)
    }

    enum Quick: String, CaseIterable, Identifiable {
        case inOneHour = "In 1 hour"
        case thisEvening = "This evening"
        case tomorrowMorning = "Tomorrow morning"
        case nextMonday = "Next Monday"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("Set a reminder")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                Button(action: onCancel) {
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

            HStack(spacing: 8) {
                ForEach(Quick.allCases) { quick in
                    quickPill(quick)
                }
            }

            HStack(spacing: 8) {
                Text("At")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                DatePicker("", selection: $selected, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .tint(accent)
                    .font(.system(size: 12))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .onChange(of: selected) { _, newValue in
                        // A hand edit that no longer matches the pill that
                        // set it deselects that pill; a quick-pill tap sets
                        // `selected` to that exact date, so this is a no-op
                        // for the tap itself.
                        if let selectedQuick, newValue != Self.quickDate(selectedQuick, reference: reference) {
                            self.selectedQuick = nil
                        }
                    }
            }

            if notificationsDenied {
                HStack(spacing: 8) {
                    Text("Notifications are off for Zumbo, so this reminder can only show in the notch while the app is running.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(action: onOpenSystemSettings) {
                        Text("Open System Settings")
                            .font(.system(size: 10, weight: .semibold))
                            .fixedSize()
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.14), in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .pointer()
                }
            } else {
                Text("A notification and a notice in the notch, at this date and time.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                pill("Cancel", filled: false) { onCancel() }
                pill("Set", filled: true) { onSet(selected) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
        .onExitCommand { onCancel() }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private func quickPill(_ quick: Quick) -> some View {
        let isSelected = selectedQuick == quick
        return Button {
            selected = Self.quickDate(quick, reference: reference)
            selectedQuick = quick
        } label: {
            Text(quick.rawValue)
                .font(.system(size: 11, weight: .medium))
                .fixedSize()
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? accent : Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .pointer()
    }

    /// Same pill language as the rest of the app: white filled for the main
    /// action, translucent white for the others, short label only.
    private func pill(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize()
                .foregroundStyle(filled ? Color.black : Color.white.opacity(0.95))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(Capsule(style: .continuous).fill(filled ? Color.white : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(filled ? .defaultAction : nil)
        .pointer()
    }

    /// The four quick pills' target dates, and the picker's initial value.
    static func quickDate(_ quick: Quick, reference: Date, calendar: Calendar = .current) -> Date {
        switch quick {
        case .inOneHour:
            return reference.addingTimeInterval(3600)
        case .thisEvening:
            let today = calendar.startOfDay(for: reference)
            let date = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: today) ?? reference
            return date > reference ? date : (calendar.date(byAdding: .day, value: 1, to: date) ?? date)
        case .tomorrowMorning:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: reference)) ?? reference
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? reference
        case .nextMonday:
            let today = calendar.startOfDay(for: reference)
            let todayWeekday = calendar.component(.weekday, from: today)
            var diff = (2 - todayWeekday + 7) % 7 // Calendar weekday 2 = Monday
            if diff == 0 { diff = 7 }
            let monday = calendar.date(byAdding: .day, value: diff, to: today) ?? reference
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: monday) ?? reference
        }
    }
}
