import SwiftUI
import WidgetKit

/// The widget extension: the Home Screen, Lock Screen and Mac desktop widgets (today, tomorrow,
/// tonight's dinner and the appointment a search found, of the family the app shows:
/// `SharedConnection`), and on iOS the cook timers' Live Activity.
@main
struct OhanaWidgets: WidgetBundle {
    var body: some Widget {
        AgendaWidget.Today()
        AgendaWidget.Tomorrow()
        DinnerWidget()
        AppointmentWidget()
        #if os(iOS)
        CookTimerLiveActivity()
        #endif
    }
}

/// The Lock Screen's families, which only iOS has.
enum LockScreenFamily {
    case circular, rectangular, inline
}

/// The families a widget offers, with the Lock Screen's where the platform has them.
private func families(home: [WidgetFamily], lockScreen: [LockScreenFamily]) -> [WidgetFamily] {
    #if os(iOS)
    home + lockScreen.map { family in
        switch family {
        case .circular: .accessoryCircular
        case .rectangular: .accessoryRectangular
        case .inline: .accessoryInline
        }
    }
    #else
    home
    #endif
}

extension WidgetFamily {
    var isInline: Bool { lockScreen == .inline }
    var isRectangular: Bool { lockScreen == .rectangular }
    var isCircular: Bool { lockScreen == .circular }

    private var lockScreen: LockScreenFamily? {
        #if os(iOS)
        switch self {
        case .accessoryCircular: .circular
        case .accessoryRectangular: .rectangular
        case .accessoryInline: .inline
        default: nil
        }
        #else
        nil
        #endif
    }
}

// MARK: Today and tomorrow

enum AgendaWidget {
    struct Today: Widget {
        var body: some WidgetConfiguration {
            StaticConfiguration(kind: WidgetStore.todayKind, provider: OhanaProvider()) { entry in
                AgendaView(entry: entry, offset: 0)
            }
            .configurationDisplayName("Today")
            .description("Today's appointments, calendar entries and birthdays.")
            .supportedFamilies(families(home: [.systemSmall, .systemMedium, .systemLarge],
                                        lockScreen: [.rectangular, .inline]))
        }
    }

    struct Tomorrow: Widget {
        var body: some WidgetConfiguration {
            StaticConfiguration(kind: WidgetStore.tomorrowKind, provider: OhanaProvider()) { entry in
                AgendaView(entry: entry, offset: 1)
            }
            .configurationDisplayName("Tomorrow")
            .description("Tomorrow's appointments, calendar entries and birthdays.")
            .supportedFamilies(families(home: [.systemSmall, .systemMedium, .systemLarge],
                                        lockScreen: [.rectangular]))
        }
    }
}

struct AgendaView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OhanaEntry
    /// 0 today, 1 tomorrow.
    let offset: Int

    private var day: Day { Day(entry.date).adding(days: offset) }

    var body: some View {
        content
            .containerBackground(for: .widget) { WidgetBackground(tint: ModuleTint.calendar) }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            let items = snapshot.items(on: day, now: entry.date)
            if family.isInline {
                inline(items)
            } else if family.isRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.widgetTitle(today: Day(entry.date))).font(.headline).widgetAccentable()
                    rows(items, limit: 2, compact: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(WidgetLink.day(snapshot, day))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeader(title: header, systemImage: offset == 0 ? "sun.max.fill" : "sunrise.fill",
                                 tint: ModuleTint.calendar)
                    rows(items, limit: limit, compact: false)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(WidgetLink.day(snapshot, day))
            }
        } else if family.isInline {
            Text(verbatim: "Ohana")
        } else {
            WidgetMessage(state: entry.state, compact: family.isRectangular)
        }
    }

    private var header: Text {
        Text(verbatim: "\(day.widgetTitle(today: Day(entry.date))) · \(day.formatted(.dateTime.day().month(.abbreviated)))")
    }

    private var limit: Int {
        switch family {
        case .systemLarge: 11
        default: 4
        }
    }

    @ViewBuilder
    private func rows(_ items: [WidgetSnapshot.Item]?, limit: Int, compact: Bool) -> some View {
        if let items {
            if items.isEmpty {
                Text("Nothing planned")
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // One line less when "+ N more" takes the last.
                let shown = items.count > limit ? limit - 1 : limit
                ForEach(items.prefix(shown)) { AgendaRow(item: $0, compact: compact) }
                if items.count > shown {
                    Text("+ \(items.count - shown) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Can't reach the server right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The next thing of the day in one line.
    @ViewBuilder
    private func inline(_ items: [WidgetSnapshot.Item]?) -> some View {
        if let next = items?.first(where: \.isTimed) ?? items?.first {
            if let start = next.start {
                Label { Text(verbatim: "\(start) \(next.title)") } icon: { Image(systemName: "calendar") }
            } else {
                Label(next.title, systemImage: "calendar")
            }
        } else {
            Label("Nothing planned", systemImage: "calendar")
        }
    }
}

// MARK: Tonight's dinner

struct DinnerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.dinnerKind, provider: OhanaProvider()) { entry in
            DinnerView(entry: entry)
        }
        .configurationDisplayName("Tonight's dinner")
        .description("What's for dinner today, from the meal plan.")
        .supportedFamilies(families(home: [.systemSmall],
                                    lockScreen: [.rectangular, .inline]))
    }
}

struct DinnerView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OhanaEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { WidgetBackground(tint: ModuleTint.meals) }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            let today = Day(entry.date)
            let dinner = snapshot.dinner(on: today)
            if family.isInline {
                Label(dinner?.title ?? String(localized: "Nothing planned"), systemImage: "fork.knife")
            } else if family.isRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tonight").font(.headline).widgetAccentable()
                    meal(snapshot, today: today)
                        .font(.caption)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(WidgetLink.dinner(snapshot, dinner))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetHeader(title: Text("Tonight"), systemImage: "fork.knife", tint: ModuleTint.meals)
                    Spacer(minLength: 0)
                    meal(snapshot, today: today)
                        .font(dinner == nil ? .subheadline : .headline)
                        .lineLimit(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(WidgetLink.dinner(snapshot, dinner))
            }
        } else if family.isInline {
            Label { Text(verbatim: "Ohana") } icon: { Image(systemName: "fork.knife") }
        } else {
            WidgetMessage(state: entry.state, compact: family.isRectangular)
        }
    }

    @ViewBuilder
    private func meal(_ snapshot: WidgetSnapshot, today: Day) -> some View {
        if !snapshot.mealsEnabled {
            Text("Meals are turned off on this server.").foregroundStyle(.secondary)
        } else if !snapshot.covers(today) {
            Text("Can't reach the server right now.").foregroundStyle(.secondary)
        } else if let dinner = snapshot.dinner(on: today) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dinner.title)
                if dinner.isLeftover {
                    Text("Leftovers").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if !snapshot.away(on: today).isEmpty {
            Text("Away · \(snapshot.away(on: today).joined(separator: ", "))").foregroundStyle(.secondary)
        } else {
            Text("Nothing planned").foregroundStyle(.secondary)
        }
    }
}

// MARK: An appointment found

struct AppointmentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.appointmentKind, provider: OhanaProvider()) { entry in
            AppointmentView(entry: entry)
        }
        .configurationDisplayName("Appointment found")
        .description("The earliest appointment your searches found.")
        .supportedFamilies(families(home: [.systemSmall, .systemMedium],
                                    lockScreen: [.rectangular, .inline]))
    }
}

struct AppointmentView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OhanaEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { WidgetBackground(tint: ModuleTint.appointments) }
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot = entry.snapshot {
            let finds = snapshot.appointmentsEnabled ? snapshot.finds(after: entry.date) : []
            if family.isInline {
                if let find = finds.first {
                    Label { Text(verbatim: "\(find.doctorName) · \(Self.slot(find.slot))") } icon: {
                        Image(systemName: "stethoscope")
                    }
                } else {
                    Label("Nothing found yet", systemImage: "stethoscope")
                }
            } else if family.isRectangular {
                VStack(alignment: .leading, spacing: 1) {
                    Text(finds.first?.searchName ?? String(localized: "Appointments"))
                        .font(.headline)
                        .lineLimit(1)
                        .widgetAccentable()
                    if let find = finds.first {
                        Text(Self.slot(find.slot)).font(.caption.weight(.semibold)).monospacedDigit()
                        Text(find.doctorName).font(.caption).lineLimit(1)
                    } else {
                        empty(snapshot).font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .widgetURL(WidgetLink.find(snapshot, finds.first))
            } else if family == .systemMedium {
                VStack(alignment: .leading, spacing: 6) {
                    header(finds)
                    if finds.isEmpty {
                        empty(snapshot).font(.subheadline)
                    } else {
                        ForEach(finds.prefix(3)) { find in
                            Link(destination: WidgetLink.find(snapshot, find)) { row(find) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(WidgetLink.find(snapshot, nil))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    header(finds)
                    Spacer(minLength: 0)
                    if let find = finds.first {
                        Text(find.slot.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                            .font(.subheadline.weight(.medium))
                        Text(find.slot.formatted(.dateTime.hour().minute()))
                            .font(.title.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(ModuleTint.appointments)
                            .widgetAccentable()
                        Text(find.doctorName).font(.caption).lineLimit(2)
                        Text(find.searchName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        empty(snapshot).font(.subheadline)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(WidgetLink.find(snapshot, finds.first))
            }
        } else if family.isInline {
            Label { Text(verbatim: "Ohana") } icon: { Image(systemName: "stethoscope") }
        } else {
            WidgetMessage(state: entry.state, compact: family.isRectangular)
        }
    }

    private func header(_ finds: [WidgetSnapshot.Find]) -> some View {
        WidgetHeader(title: finds.count > 1 ? Text("Appointments found") : finds.isEmpty ? Text("Appointments") : Text("Appointment found"),
                     systemImage: "stethoscope", tint: ModuleTint.appointments)
    }

    private func row(_ find: WidgetSnapshot.Find) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.slot(find.slot))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ModuleTint.appointments)
                .widgetAccentable()
            Text(verbatim: "\(find.doctorName) · \(find.searchName)")
                .font(.subheadline)
                .lineLimit(1)
        }
    }

    private func empty(_ snapshot: WidgetSnapshot) -> some View {
        Text(snapshot.appointmentsEnabled ? "Nothing found yet" : "Appointments are turned off on this server.")
            .foregroundStyle(.secondary)
    }

    /// "Tue 4 Nov, 09:30".
    static func slot(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

// MARK: Previews

#Preview("Today", as: .systemSmall) {
    AgendaWidget.Today()
} timeline: {
    OhanaEntry(date: Date(), state: .ready(.sample()))
    OhanaEntry(date: Date(), state: .signedOut)
}
