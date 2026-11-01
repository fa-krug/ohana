import ActivityKit
import SwiftUI
import WidgetKit

/// The cook timers on the Lock Screen and in the Dynamic Island (the app's `CookTimers` keeps the
/// activity up to date). The countdowns run by themselves: `Text(timerInterval:)` and
/// `ProgressView(timerInterval:)` need no updates.
struct CookTimerLiveActivity: Widget {
    /// The meals module's tint (`ModuleTint.meals` in the app).
    static let tint = Color.orange

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CookTimerAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activitySystemActionForegroundColor(Self.tint)
        } dynamicIsland: { context in
            let timers = context.state.timers
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(Self.tint)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if let next = timers.first {
                        Countdown(timer: next)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Self.tint)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if let next = timers.first {
                        TimerTitle(timer: next)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        if let next = timers.first {
                            ProgressView(timerInterval: next.start...next.end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                                .tint(Self.tint)
                        }
                        ForEach(timers.dropFirst()) { timer in
                            HStack {
                                Text(verbatim: timer.title).lineLimit(1)
                                Spacer()
                                Countdown(timer: timer)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        MoreLabel(count: context.state.more)
                    }
                }
            } compactLeading: {
                Image(systemName: "timer")
                    .foregroundStyle(Self.tint)
            } compactTrailing: {
                if let next = timers.first {
                    Countdown(timer: next)
                        .foregroundStyle(Self.tint)
                        .frame(maxWidth: next.end.timeIntervalSince(next.start) >= 3600 ? 64 : 44)
                }
            } minimal: {
                if let next = timers.first {
                    ProgressView(timerInterval: next.start...next.end, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "timer")
                    }
                    .progressViewStyle(.circular)
                    .tint(Self.tint)
                } else {
                    Image(systemName: "timer").foregroundStyle(Self.tint)
                }
            }
            .keylineTint(Self.tint)
        }
    }
}

private struct LockScreenView: View {
    let state: CookTimerAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(state.timers) { timer in
                HStack(alignment: .center, spacing: 12) {
                    ProgressView(timerInterval: timer.start...timer.end, countsDown: true) {
                        EmptyView()
                    } currentValueLabel: {
                        Image(systemName: "timer").font(.caption.weight(.semibold))
                    }
                    .progressViewStyle(.circular)
                    .tint(CookTimerLiveActivity.tint)
                    .frame(width: 36, height: 36)
                    TimerTitle(timer: timer)
                    Spacer(minLength: 8)
                    Countdown(timer: timer)
                        .font(.title.weight(.semibold))
                        .foregroundStyle(CookTimerLiveActivity.tint)
                }
            }
            MoreLabel(count: state.more)
        }
    }
}

private struct TimerTitle: View {
    let timer: CookTimerAttributes.Timer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: timer.title)
                .font(.headline)
                .lineLimit(1)
            Text(verbatim: timer.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The time left, counting down by itself (0:00 once done).
private struct Countdown: View {
    let timer: CookTimerAttributes.Timer

    var body: some View {
        Text(timerInterval: timer.start...timer.end, countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

private struct MoreLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(verbatim: "+\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
