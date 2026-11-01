import SwiftUI
import WidgetKit

/// Links into the app: `ohana://f/{familyId}/…`, the paths the app's `AppRoute.parse` knows.
enum WidgetLink {
    static func url(_ snapshot: WidgetSnapshot, _ path: String) -> URL {
        let family = snapshot.familyID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? snapshot.familyID
        return URL(string: "ohana://f/\(family)/\(path)")!
    }

    static func day(_ snapshot: WidgetSnapshot, _ day: Day) -> URL { url(snapshot, "calendar/\(day)") }

    /// Tonight's recipe, or the meal plan.
    static func dinner(_ snapshot: WidgetSnapshot, _ dinner: WidgetSnapshot.Dinner?) -> URL {
        dinner.map { url(snapshot, "meals/recipes/\($0.recipeID)") } ?? url(snapshot, "meals/plan")
    }

    static func shopping(_ snapshot: WidgetSnapshot) -> URL {
        url(snapshot, "meals/shopping" + (snapshot.shopping.map { "/\($0.listID)" } ?? ""))
    }

    static func find(_ snapshot: WidgetSnapshot, _ find: WidgetSnapshot.Find?) -> URL {
        find.map { url(snapshot, "appointments/\($0.searchID)/slots/\($0.resultID)") } ?? url(snapshot, "appointments")
    }
}

/// The widget's backdrop: the system's, with a faint wash of the module's color (none in the
/// tinted and clear looks, where the system draws its own).
struct WidgetBackground: View {
    var tint: Color

    var body: some View {
        LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0.03)], startPoint: .top, endPoint: .bottom)
    }
}

/// "Tonight", "Today · Sun 1 Nov": a widget's heading, in the module's color.
struct WidgetHeader: View {
    var title: Text
    var systemImage: String
    var tint: Color

    var body: some View {
        Label { title } icon: { Image(systemName: systemImage) }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .widgetAccentable()
    }
}

/// What a widget shows without a family: signed out in the app, or nothing loaded yet.
struct WidgetMessage: View {
    let state: OhanaEntry.State
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !compact {
                Image(systemName: "house.fill")
                    .font(.title3)
                    .foregroundStyle(Color.ohana)
                    .widgetAccentable()
                Spacer(minLength: 0)
            }
            Text(text)
                .font(compact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(compact ? 2 : 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var text: LocalizedStringKey {
        switch state {
        case .signedOut: "Open Ohana to connect your family."
        case .unavailable, .ready: "Can't reach the server right now."
        }
    }
}

/// One line of a day: a calendar type's color, a time or "All day", a birthday cake.
struct AgendaRow: View {
    let item: WidgetSnapshot.Item
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            Text(title)
                .lineLimit(1)
        }
        .font(compact ? .caption : .subheadline)
    }

    @ViewBuilder
    private var marker: some View {
        switch item.kind {
        case .run:
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(widgetHex: item.color ?? ""))
                .frame(width: 8, height: 8)
                .widgetAccentable()
                .accessibilityHidden(true)
        case .birthday:
            Text(verbatim: "🎂").font(.caption2).accessibilityHidden(true)
        case .event:
            if let start = item.start {
                Text(start)
                    .monospacedDigit()
                    .fontWeight(.semibold)
                    .foregroundStyle(item.isAppointment ? ModuleTint.appointments : ModuleTint.calendar)
                    .widgetAccentable()
            } else {
                Image(systemName: item.isAppointment ? "stethoscope" : "calendar")
                    .font(.caption2)
                    .foregroundStyle(ModuleTint.calendar)
                    .widgetAccentable()
                    .accessibilityHidden(true)
            }
        }
    }

    private var title: String {
        if item.kind == .birthday, let age = item.age {
            return String(localized: "\(item.title) turns \(age)")
        }
        return item.title
    }
}

extension Day {
    /// "Today" / "Tomorrow" as the header says it.
    func widgetTitle(today: Day) -> String {
        if self == today { return String(localized: "Today") }
        if self == today.adding(days: 1) { return String(localized: "Tomorrow") }
        return formatted(.dateTime.weekday(.wide))
    }
}

extension Color {
    /// A color from the server's "#rrggbb"; gray when unreadable.
    init(widgetHex hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            self = .gray
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

extension WidgetSnapshot {
    /// What the gallery and placeholders show: a made-up family's day.
    static func sample(now: Date = Date()) -> WidgetSnapshot {
        let today = Day(now)
        let tomorrow = today.adding(days: 1)
        return WidgetSnapshot(
            familyID: "sample",
            familyName: "Ohana",
            loadedAt: now,
            today: today,
            items: [
                Item(kind: .run, id: "r1", day: today, title: String(localized: "School"), color: "#3b82f6"),
                Item(kind: .birthday, id: "b1", day: today, title: String(localized: "Grandma"), age: 70),
                Item(kind: .event, id: "e1", day: today, title: String(localized: "Swimming lesson · Mia"),
                     start: "16:30", end: "17:30"),
                Item(kind: .event, id: "e2", day: today, title: String(localized: "Parents' evening"), start: "19:00"),
                Item(kind: .run, id: "r2", day: tomorrow, title: String(localized: "School"), color: "#3b82f6"),
                Item(kind: .event, id: "e3", day: tomorrow, title: String(localized: "Pediatrician · Leo"),
                     start: "08:15", end: "09:00", isAppointment: true),
                Item(kind: .event, id: "e4", day: tomorrow, title: String(localized: "Football practice"), start: "17:00"),
            ],
            awayToday: [],
            dinner: Dinner(recipeID: "sample", title: String(localized: "Vegetable lasagne"), isLeftover: false),
            shopping: Shopping(listID: "sample", date: tomorrow, open: 7, total: 18),
            finds: [
                Find(searchID: "s1", searchName: String(localized: "Dermatologist"), resultID: 1,
                     doctorName: String(localized: "Dr. Weber"),
                     slot: WidgetSnapshot.date(today.adding(days: 3), "09:30") ?? now, doctors: 3),
            ]
        )
    }
}
