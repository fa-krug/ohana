import SwiftUI
import WidgetKit

/// The widget extension (iOS): for now only the cook timers' Live Activity.
@main
struct OhanaWidgets: WidgetBundle {
    var body: some Widget {
        CookTimerLiveActivity()
    }
}
