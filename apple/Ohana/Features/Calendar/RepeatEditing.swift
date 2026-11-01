import Foundation

/// What the Repeat and End Repeat controls edit (`CalendarEventRepeatSection`,
/// `CalendarRepeatRuleEditor`): a draft with an RRULE and the day it starts on. Calendar events
/// and chores repeat the same way, so they share the controls.
protocol RepeatEditing {
    /// The rule as the server stores it; nil: it doesn't repeat.
    var repeatRRule: String? { get set }
    /// The first day: its weekday and day of the month are the rule's when it names none.
    var repeatStart: Day { get }
    /// What's wrong with the rule, nil when it can be saved (an event's by default).
    var repeatProblem: String? { get }
}

extension RepeatEditing {
    var rule: RepeatRule? { repeatRRule.flatMap(RepeatRule.init) }

    /// The Repeat menu: a preset keeps the end the rule had; Never stops it repeating. Custom is
    /// the editor's own page (`setRule`).
    var repeatChoice: CalendarRepeatChoice { CalendarRepeatChoice(rule) }

    mutating func setRepeat(_ choice: CalendarRepeatChoice) {
        switch choice {
        case .never: repeatRRule = nil
        case .custom: if rule == nil { setRule(RepeatRule(.weekly)) }
        default:
            guard var next = choice.rule else { return }
            next.end = rule?.end ?? .never
            setRule(next)
        }
    }

    mutating func setRule(_ rule: RepeatRule) {
        repeatRRule = rule.string
    }

    /// End Repeat: never, on a day, after a number of times.
    mutating func setRepeatEnd(_ end: RepeatRule.End) {
        guard var next = rule else { return }
        next.end = end
        setRule(next)
    }

    var repeatProblem: String? {
        repeatProblem(endsTooEarly: String(localized: "The repeat must end after the event starts."))
    }

    /// A rule that can't be read, or one that ends before the first day (`endsTooEarly` says so).
    func repeatProblem(endsTooEarly: String) -> String? {
        guard let rrule = repeatRRule else { return nil }
        guard let rule = RepeatRule(rrule) else { return String(localized: "This repeat rule can’t be read.") }
        if case let .until(day) = rule.end, day < repeatStart { return endsTooEarly }
        return nil
    }
}
