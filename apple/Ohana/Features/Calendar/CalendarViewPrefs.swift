import CoreGraphics
import Foundation

/// The zoom of the year grid (the web's view-prefs.ts): how many days fit across it, from 7 to
/// all 31. Kept per device under the web's key.
enum CalendarZoom {
    static let min = 7
    static let max = 31
    static let initial = 31
    static let key = "ohana.calendar.daysWide"
    /// From this zoom on, the cells are big enough for weekday letters.
    static let showWeekdays = 16

    static func clamp(_ n: Int) -> Int { Swift.min(max, Swift.max(min, n)) }

    /// ⌘+ (dir 1) and ⌘− (dir −1) step by about a quarter; 0 resets (the web's `zoomBy`).
    static func step(_ n: Int, _ dir: Int) -> Int {
        let n = clamp(n)
        if dir == 0 { return initial }
        if dir > 0 { return clamp(Swift.min(n - 1, Int((Double(n) / 1.25).rounded()))) }
        return clamp(Swift.max(n + 1, Int((Double(n) * 1.25).rounded())))
    }

    /// A pinch that started at `start`: spreading the fingers (magnification > 1) zooms in,
    /// so fewer days fit.
    static func pinched(from start: Int, magnification: CGFloat) -> Int {
        guard magnification > 0 else { return clamp(start) }
        return clamp(Int((CGFloat(start) / magnification).rounded()))
    }

    /// The slider runs from zoomed out (left) to zoomed in (right).
    static func sliderValue(_ zoom: Int) -> Double { Double(min + max - clamp(zoom)) }
    static func zoom(sliderValue: Double) -> Int { clamp(min + max - Int(sliderValue.rounded())) }
}

/// Which layout the calendar uses.
enum CalendarLayoutRule {
    /// Narrower than this, the calendar shows the year as a list of months instead of the
    /// 12 × 31 grid: its own width, not the screen's (the sidebar and the assistant take their
    /// share), like the web's `MONTH_VIEW_BELOW`.
    static let monthListBelow: CGFloat = 880

    static func monthList(width: CGFloat?, compact: Bool) -> Bool {
        if compact { return true }
        guard let width else { return false }
        return width < monthListBelow
    }
}

/// A request to scroll a day into view: centered (a route, the next gap, today) or just
/// enough to see it (arrow keys).
struct CalendarReveal: Equatable {
    let day: Day
    var center = true
    private let id = UUID()

    init(_ day: Day, center: Bool = true) {
        self.day = day
        self.center = center
    }
}
