import SwiftUI

/// The event editor's Repeat and End Repeat, like Apple Calendar's: the presets, Custom… (its own
/// page, `CalendarRepeatRuleEditor`), and when it stops. A rule the editor doesn't make (from
/// Apple Calendar or the assistant) shows as its summary and stays as it is unless changed.
struct CalendarEventRepeatSection: View {
    @Binding var draft: CalendarEventDraft
    @Binding var custom: Bool

    private enum EndKind: Hashable { case never, date, count }

    var body: some View {
        Section {
            Picker("Repeat", selection: Binding(get: { draft.repeatChoice }, set: { choice in
                draft.setRepeat(choice)
                if choice == .custom { custom = true }
            })) {
                ForEach(CalendarRepeatChoice.allCases) { Text($0.title).tag($0) }
            }
            if let rule = draft.rule, draft.repeatChoice == .custom {
                Button {
                    custom = true
                } label: {
                    HStack {
                        Label(rule.summary(), systemImage: "repeat")
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Change how it repeats"))
            }
            if let rule = draft.rule {
                Picker("End Repeat", selection: Binding(get: { endKind(rule.end) }, set: { setEnd($0) })) {
                    Text("Never").tag(EndKind.never)
                    Text("On Date").tag(EndKind.date)
                    Text("After").tag(EndKind.count)
                }
                switch rule.end {
                case .never:
                    EmptyView()
                case let .until(day):
                    DatePicker("Until", selection: Binding(get: { day.date }, set: { draft.setRepeatEnd(.until(Day($0))) }),
                               in: draft.input.date.date..., displayedComponents: .date)
                case let .count(n):
                    Stepper(value: Binding(get: { n }, set: { draft.setRepeatEnd(.count($0)) }), in: 1...999) {
                        Text("\(n) times")
                    }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let problem = draft.repeatProblem {
                    Text(problem).foregroundStyle(.red)
                }
                if let rule = draft.rule, !rule.isEditable {
                    Text("Made elsewhere (Apple Calendar, the assistant): it stays as it is unless you change it.")
                }
            }
        }
    }

    private func endKind(_ end: RepeatRule.End) -> EndKind {
        switch end {
        case .never: .never
        case .until: .date
        case .count: .count
        }
    }

    private func setEnd(_ kind: EndKind) {
        switch kind {
        case .never: draft.setRepeatEnd(.never)
        case .date: draft.setRepeatEnd(.until(draft.input.date.adding(months: 3)))
        case .count: draft.setRepeatEnd(.count(10))
        }
    }
}

/// Custom…: how often (daily, weekly, monthly, yearly, every n), on which weekdays, on which day
/// of the month (the 15th, the last Friday).
struct CalendarRepeatRuleEditor: View {
    @Binding var draft: CalendarEventDraft

    private enum MonthlyMode: Hashable { case day, weekday }

    /// The rule as the controls show it: one they don't make shows its frequency, interval and end
    /// (changing anything replaces it).
    private var rule: RepeatRule {
        guard let rule = draft.rule else { return RepeatRule(.weekly) }
        return rule.isEditable ? rule : RepeatRule(rule.frequency, interval: rule.interval, end: rule.end)
    }

    private var start: Day { draft.input.date }

    var body: some View {
        Form {
            Section {
                Picker("Frequency", selection: Binding(get: { rule.frequency }, set: { setFrequency($0) })) {
                    Text("Daily").tag(RepeatRule.Frequency.daily)
                    Text("Weekly").tag(RepeatRule.Frequency.weekly)
                    Text("Monthly").tag(RepeatRule.Frequency.monthly)
                    Text("Yearly").tag(RepeatRule.Frequency.yearly)
                }
                Stepper(value: Binding(get: { rule.interval }, set: { n in change { $0.interval = n } }), in: 1...99) {
                    Text(intervalText)
                }
            } footer: {
                if let current = draft.rule {
                    Text(current.summary())
                }
            }
            switch rule.frequency {
            case .weekly: weekdaysSection
            case .monthly: monthlySection
            default: EmptyView()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Custom")
    }

    private var intervalText: String {
        let n = rule.interval
        switch rule.frequency {
        case .daily: return String(localized: "Every \(n) days")
        case .weekly: return String(localized: "Every \(n) weeks")
        case .monthly: return String(localized: "Every \(n) months")
        case .yearly: return String(localized: "Every \(n) years")
        }
    }

    /// The weekdays of a weekly rule, in the device's week order; without any it repeats on the
    /// event's own weekday, which shows as chosen.
    private var weekdaysSection: some View {
        let first = Calendar.current.firstWeekday
        let chosen = Set(rule.weekdays.isEmpty ? [startWeekday] : rule.weekdays.map(\.weekday))
        return Section("On") {
            ForEach(0..<7, id: \.self) { offset in
                let weekday = (first - 1 + offset) % 7 + 1
                Button {
                    toggle(weekday, in: chosen)
                } label: {
                    HStack {
                        Text(RepeatRule.weekdayName(weekday)).foregroundStyle(.primary)
                        Spacer()
                        if chosen.contains(weekday) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen.contains(weekday) ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private var monthlySection: some View {
        let monthly = CalendarMonthlyRepeat(rule, start: start) ?? .day(start.day)
        Section {
            Picker("Repeats on", selection: Binding(get: { mode(monthly) }, set: { setMode($0) })) {
                Text("Day of the month").tag(MonthlyMode.day)
                Text("Weekday of the month").tag(MonthlyMode.weekday)
            }
            .pickerStyle(.segmented)
            switch monthly {
            case let .day(n):
                Picker("Day", selection: Binding(get: { n }, set: { setMonthly(.day($0)) })) {
                    ForEach(1...31, id: \.self) { Text(RepeatRule.ordinal($0)).tag($0) }
                }
            case let .weekday(ordinal, weekday):
                Picker("Which", selection: Binding(get: { ordinal }, set: { setMonthly(.weekday(ordinal: $0, weekday: weekday)) })) {
                    Text("first").tag(1)
                    Text("second").tag(2)
                    Text("third").tag(3)
                    Text("fourth").tag(4)
                    Text("fifth").tag(5)
                    Text("last").tag(-1)
                }
                Picker("Weekday", selection: Binding(get: { weekday }, set: { setMonthly(.weekday(ordinal: ordinal, weekday: $0)) })) {
                    ForEach(RepeatRule.sortedWeekdays(Array(1...7)), id: \.self) { Text(RepeatRule.weekdayName($0)).tag($0) }
                }
            }
        } footer: {
            if case let .day(n) = monthly, n > 28 {
                Text("Months without that day are skipped.")
            }
        }
    }

    private var startWeekday: Int { CalendarMath.weekday(start) + 1 }

    private func mode(_ monthly: CalendarMonthlyRepeat) -> MonthlyMode {
        if case .weekday = monthly { .weekday } else { .day }
    }

    private func change(_ edit: (inout RepeatRule) -> Void) {
        var next = rule
        edit(&next)
        draft.setRule(next)
    }

    /// Another frequency starts over with its interval and end.
    private func setFrequency(_ frequency: RepeatRule.Frequency) {
        guard frequency != rule.frequency else { return }
        draft.setRule(RepeatRule(frequency, interval: rule.interval, end: rule.end))
    }

    /// At least one weekday stays; the event's own weekday alone is left implicit (plain weekly).
    private func toggle(_ weekday: Int, in chosen: Set<Int>) {
        var days = chosen
        if days.contains(weekday) {
            guard days.count > 1 else { return }
            days.remove(weekday)
        } else {
            days.insert(weekday)
        }
        change { rule in
            rule.weekdays = days == [startWeekday] ? [] : RepeatRule.sortedWeekdays(Array(days)).map { RepeatRule.WeekdayEntry($0) }
        }
    }

    private func setMode(_ mode: MonthlyMode) {
        switch mode {
        case .day: setMonthly(.day(start.day))
        case .weekday:
            let position = CalendarMonthlyRepeat.position(of: start)
            setMonthly(.weekday(ordinal: position.ordinal, weekday: position.weekday))
        }
    }

    private func setMonthly(_ monthly: CalendarMonthlyRepeat) {
        let start = start
        change { monthly.apply(to: &$0, start: start) }
    }
}
