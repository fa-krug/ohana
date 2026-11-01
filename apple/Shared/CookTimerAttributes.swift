#if canImport(ActivityKit)
import ActivityKit
import Foundation

/// The cook view's running timers as one Live Activity (Lock Screen and Dynamic Island), shared by
/// the app (`CookTimers`, which starts, updates and ends it) and the widget extension (which draws
/// it). The texts arrive translated by the app.
nonisolated struct CookTimerAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The running timers, soonest first.
        var timers: [Timer]
        /// How many more run than `timers` holds.
        var more: Int = 0
    }

    struct Timer: Codable, Hashable, Identifiable {
        var id: String
        /// "Step 3"
        var title: String
        /// The recipe.
        var subtitle: String
        var start: Date
        var end: Date
    }
}
#endif
