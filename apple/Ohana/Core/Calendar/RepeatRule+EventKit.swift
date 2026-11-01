import EventKit
import Foundation

// A `RepeatRule` as EventKit's and back: Apple Calendar's events (`AppleCalendarSync`,
// `DeviceCalendarStore`) and the chores' reminders (`RemindersStore`) repeat by these.

extension RepeatRule {
    /// EventKit's rule for it (EventKit has no week start of its own to set).
    var ekRule: EKRecurrenceRule {
        let frequency: EKRecurrenceFrequency = switch frequency {
        case .daily: .daily
        case .weekly: .weekly
        case .monthly: .monthly
        case .yearly: .yearly
        }
        let days = weekdays.compactMap { entry -> EKRecurrenceDayOfWeek? in
            guard let weekday = EKWeekday(rawValue: entry.weekday) else { return nil }
            return entry.ordinal.map { EKRecurrenceDayOfWeek(weekday, weekNumber: $0) } ?? EKRecurrenceDayOfWeek(weekday)
        }
        let end: EKRecurrenceEnd? = switch end {
        case .never: nil
        // The end of the day, so its last occurrence is in at any time.
        case let .until(day): EKRecurrenceEnd(end: Day.calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day.date) ?? day.date)
        case let .count(n): EKRecurrenceEnd(occurrenceCount: n)
        }
        func numbers(_ list: [Int]) -> [NSNumber]? { list.isEmpty ? nil : list.map { NSNumber(value: $0) } }
        return EKRecurrenceRule(
            recurrenceWith: frequency, interval: interval, daysOfTheWeek: days.isEmpty ? nil : days,
            daysOfTheMonth: numbers(monthDays), monthsOfTheYear: numbers(months),
            weeksOfTheYear: numbers(weekNumbers), daysOfTheYear: numbers(yearDays),
            setPositions: numbers(setPositions), end: end
        )
    }

    /// The rule of EventKit's; nil for a frequency Ohana doesn't have.
    init?(eventKit rule: EKRecurrenceRule) {
        let frequency: RepeatRule.Frequency
        switch rule.frequency {
        case .daily: frequency = .daily
        case .weekly: frequency = .weekly
        case .monthly: frequency = .monthly
        case .yearly: frequency = .yearly
        @unknown default: return nil
        }
        let end: RepeatRule.End = if let count = rule.recurrenceEnd?.occurrenceCount, count > 0 {
            .count(count)
        } else if let date = rule.recurrenceEnd?.endDate {
            .until(Day(date))
        } else {
            .never
        }
        self.init(
            frequency, interval: rule.interval,
            weekdays: (rule.daysOfTheWeek ?? []).map {
                RepeatRule.WeekdayEntry($0.dayOfTheWeek.rawValue, ordinal: $0.weekNumber == 0 ? nil : $0.weekNumber)
            },
            monthDays: (rule.daysOfTheMonth ?? []).map(\.intValue), months: (rule.monthsOfTheYear ?? []).map(\.intValue),
            yearDays: (rule.daysOfTheYear ?? []).map(\.intValue), weekNumbers: (rule.weeksOfTheYear ?? []).map(\.intValue),
            setPositions: (rule.setPositions ?? []).map(\.intValue),
            weekStart: rule.firstDayOfTheWeek == 0 ? nil : rule.firstDayOfTheWeek, end: end
        )
    }
}
