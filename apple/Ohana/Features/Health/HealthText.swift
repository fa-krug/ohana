import SwiftUI

/// How an item reads: its status as a symbol and a line ("Due until 10 May 2027").
enum HealthText {
    static func date(_ day: Day) -> String {
        day.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func systemImage(_ status: HealthStatus) -> String {
        switch status {
        case .done: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .due: "exclamationmark.circle.fill"
        case .upcoming: "circle"
        case .past: "circle.dashed"
        case .unknown: "questionmark.circle"
        }
    }

    static func tint(_ status: HealthStatus) -> Color {
        switch status {
        case .done: .green
        case .due: .orange
        case .skipped, .upcoming, .past, .unknown: .secondary
        }
    }

    static func label(_ status: HealthStatus) -> String {
        switch status {
        case .done: String(localized: "Completed")
        case .skipped: String(localized: "Skipped")
        case .due: String(localized: "Due")
        case .upcoming: String(localized: "Coming up")
        case .past: String(localized: "Not recorded")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// The line under an item's title.
    static func line(_ item: HealthItem) -> String {
        switch item.status {
        case .done, .skipped: recorded(item)
        case .due: due(item)
        case .upcoming: upcoming(item)
        case .past: String(localized: "Not recorded")
        case .unknown:
            item.repeats
                ? String(localized: "When was the last one?")
                : String(localized: "Date of the first dose unknown")
        }
    }

    /// "Done on 20 Oct 2026", a repeating one's next time after it.
    private static func recorded(_ item: HealthItem) -> String {
        let day = item.latest?.day.map { date($0) }
        var text = switch (item.status == .done, day) {
        case let (true, day?): String(localized: "Done on \(day)")
        case (true, nil): String(localized: "Done, date unknown")
        case let (false, day?): String(localized: "Skipped on \(day)")
        case (false, nil): String(localized: "Skipped")
        }
        if item.repeats, item.status == .done, let next = item.from {
            text += " · " + String(localized: "next \(date(next))")
        }
        return text
    }

    private static func upcoming(_ item: HealthItem) -> String {
        guard let from = item.from else { return String(localized: "After the first dose") }
        return String(localized: "Due from \(date(from))")
    }

    private static func due(_ item: HealthItem) -> String {
        if let until = item.until { return String(localized: "Due until \(date(until))") }
        if let from = item.from { return String(localized: "Due since \(date(from))") }
        return String(localized: "Due")
    }
}
