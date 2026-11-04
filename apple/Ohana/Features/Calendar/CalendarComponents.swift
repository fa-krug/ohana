import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

extension Color {
    /// A type's color ("#22c55e"); gray for anything else.
    init(calendarHex hex: String) {
        if let (r, g, b) = CalendarMath.rgb(hex) {
            self.init(.sRGB, red: r, green: g, blue: b)
        } else {
            self = .gray
        }
    }
}

/// A type's color as the days draw it in a color scheme (in dark mode grays quieter,
/// `CalendarMath.typeRGB`), and the ink that reads on it: black or white.
struct CalendarTypeColor {
    let fill: Color
    let darkInk: Bool
    var ink: Color { darkInk ? .black : .white }

    init(_ hex: String, scheme: ColorScheme) {
        if let (r, g, b) = CalendarMath.typeRGB(hex, dark: scheme == .dark) {
            fill = Color(.sRGB, red: r, green: g, blue: b)
            darkInk = CalendarMath.prefersDarkText(r: r, g: g, b: b)
        } else {
            fill = .gray
            darkInk = true
        }
    }
}

/// What the days of the grids share in how they look (the year canvas and `CalendarDayCell`).
enum CalendarDayLook {
    /// An empty day's fill: weekends darker, so the weeks read as a rhythm at a glance.
    static func base(weekend: Bool, scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        return .primary.opacity(weekend ? (dark ? 0.12 : 0.085) : 0.03)
    }

    /// Over a weekend filled with a type's color: a little darker, so weekends still read.
    static let weekendShade = Color.black.opacity(0.08)
    /// Days before today: the content faded (the selection, focus, today and drop marks aren't).
    static let pastOpacity = 0.55
    /// Days without the legend's highlighted types: their content faded further.
    static let dimmedOpacity = 0.25

    /// How strongly a day's content draws: the past days' fade times the highlight's.
    static func contentOpacity(past: Bool, dimmed: Bool) -> Double {
        (past ? pastOpacity : 1) * (dimmed ? dimmedOpacity : 1)
    }
    /// The "needs cover" stripes: thin and in the band's ink, so they don't shimmer.
    static let stripeWidth: CGFloat = 1
    static let stripeOpacity = 0.18
    /// The events mark shows the count from two events on, in cells at least this wide.
    static let countMinWidth: CGFloat = 24

    /// The count in the events mark ("2", "9+").
    static func eventCount(_ n: Int) -> String { n > 9 ? "9+" : String(n) }
}

/// The system pasteboard as plain text.
enum CalendarPasteboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static var string: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

/// Texts of the calendar shared by its views.
enum CalendarText {
    static func day(_ d: Day) -> String { d.formatted() }

    static func longDay(_ d: Day) -> String {
        d.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func span(_ days: [Day]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        return days.count == 1 ? day(first) : "\(day(first)) – \(day(last))"
    }

    static func month(year: Int, month: Int) -> String {
        Day(year: year, month: month, day: 1).formatted(.dateTime.month(.wide).year())
    }

    static func monthName(_ month: Int) -> String {
        Day(year: 2001, month: month, day: 1).formatted(.dateTime.month(.wide))
    }

    static func shortMonth(_ month: Int) -> String {
        Day(year: 2001, month: month, day: 1).formatted(.dateTime.month(.abbreviated))
    }

    static func birthday(_ b: CalendarBirthday) -> String {
        String(localized: "🎂 \(b.name) turns \(b.age)")
    }

    /// A holiday on a day: its name (its type's color already marks the day).
    static func holiday(_ h: CalendarHoliday) -> String { h.name }

    /// A string with a plural: English inflects `^[\(n) day](inflect: true)`, the German
    /// translation has one/other variants. (`String(localized:)` leaves the markup as it is.)
    static func plural(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }

    /// "1 day", "5 days".
    static func days(_ n: Int) -> String { plural("^[\(n) day](inflect: true)") }
    static func weekdays(_ n: Int) -> String { plural("^[\(n) weekday](inflect: true)") }
    static func workdays(_ n: Int) -> String { plural("^[\(n) workday](inflect: true)") }

    /// The selection bar's title: "Saturday, 7 March", or "Mon 3 Mar – Fri 7 Mar".
    static func selectionTitle(_ days: [Day]) -> String {
        guard days.count == 1, let first = days.first else { return span(days) }
        return first.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// Under it for several days: "5 days", "7 days, 5 weekdays" (the weekdays only when some
    /// are weekends and some aren't).
    static func selectionCount(_ days: [Day]) -> String {
        let work = days.filter { !CalendarMath.isWeekend($0) }.count
        guard work > 0, work < days.count else { return Self.days(days.count) }
        return "\(Self.days(days.count)), \(weekdays(work))"
    }

    /// While the fill handle is dragged: how many days it fills.
    static func fill(_ fill: CalendarFill) -> String {
        fill.targets.isEmpty
            ? String(localized: "Drag past the selection to repeat it")
            : String(localized: "Fill \(days(fill.targets.count))")
    }

    /// "It is used on 3 days in 2026. This can’t be undone."
    static func usedOn(_ n: Int, year: Int) -> String {
        plural("It is used on ^[\(n) day](inflect: true) in \(String(year)). This can’t be undone.")
    }

    /// Weekday letters in the order of the device's week (`firstWeekday`).
    static var weekdayLetters: [String] {
        inWeekOrder(Calendar.current.veryShortStandaloneWeekdaySymbols, firstWeekday: Calendar.current.firstWeekday)
    }

    /// Short weekday names ("Mon") in the order of the device's week (the web's month view).
    static var weekdayNames: [String] {
        inWeekOrder(Calendar.current.shortStandaloneWeekdaySymbols, firstWeekday: Calendar.current.firstWeekday)
    }

    /// Sunday-first weekday symbols reordered for a week starting on `firstWeekday` (1 = Sunday).
    static func inWeekOrder(_ symbols: [String], firstWeekday: Int) -> [String] {
        (0..<7).map { symbols[(firstWeekday - 1 + $0) % 7] }
    }

    /// What VoiceOver says after the selection changed: "3 days selected", "No days selected".
    static func selectionAnnouncement(_ count: Int) -> String {
        count == 0 ? String(localized: "No days selected") : plural("^[\(count) day](inflect: true) selected")
    }
}

/// The colors of a day's entry types as bands one above the other (the web grid's fills).
struct CalendarFills: View {
    let types: [CalendarEntryType]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 1) {
            ForEach(types) { type in
                let color = CalendarTypeColor(type.color, scheme: scheme)
                color.fill
                    .overlay {
                        if type.role == .needsCover {
                            // "Needs cover" bands are striped, like the web's (only that type's band).
                            CalendarStripes(ink: color.ink)
                        }
                    }
            }
        }
    }
}

/// A shape rather than a `Canvas`: a year can have hundreds of striped days, and every canvas
/// is a drawing of its own.
struct CalendarStripes: View {
    /// The band's ink (black on light colors, white on dark ones).
    var ink: Color = .white

    var body: some View {
        Lines()
            .stroke(ink.opacity(CalendarDayLook.stripeOpacity), lineWidth: CalendarDayLook.stripeWidth)
            .clipped()
            .allowsHitTesting(false)
    }

    /// The stripes over `rect` (the year grid draws them itself).
    nonisolated static func path(in rect: CGRect) -> Path {
        var path = Path()
        let step: CGFloat = 6
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += step
        }
        return path
    }

    private nonisolated struct Lines: Shape {
        func path(in rect: CGRect) -> Path { CalendarStripes.path(in: rect) }
    }
}

/// The year's types as toggle chips (their badges), in one row that scrolls (in the
/// selection bar), and the way to edit them; on the selection they add or remove the type. A
/// year without types offers to copy them from another year.
struct CalendarTypeChips: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.colorScheme) private var scheme
    @Bindable var store: CalendarStore

    var body: some View {
        if store.types.isEmpty {
            if store.typeYears != nil { CalendarEmptyTypes(store: store) }
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 8) { chips }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    @ViewBuilder
    private var chips: some View {
        let stats = store.stats
        ForEach(Array(store.types.enumerated()), id: \.element.id) { index, type in
            chip(type, index: index, stats: stats[type.id] ?? CalendarTypeStats())
        }
        if !store.readOnly {
            Button {
                family.open(.settings(.calendar))
            } label: {
                Label("Edit types", systemImage: "pencil")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .help("Edit types")
        }
    }

    /// A chip of the type's badge: the type's color around it and tinted while every selected day
    /// has it. A tap toggles it; its name, member and counts are in the tip (hover on the Mac, a
    /// long press elsewhere, which doesn't toggle it) and the accessibility label. Not a `Button`:
    /// a button would also fire when a long press ends.
    private func chip(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> some View {
        let active = store.selectionHas(type.id)
        let color = CalendarTypeColor(type.color, scheme: scheme).fill
        let member = store.member(of: type)
        return CalendarTypeBadge(type: type, member: member, size: 24, help: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 36)
            .background(active ? color.opacity(0.28) : Color.primary.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(active ? color : Color.primary.opacity(0.12), lineWidth: active ? 1.5 : 1))
            .contentShape(.capsule)
            #if os(iOS)
            .hoverEffect()
            #endif
            .onTapGesture { toggle(type) }
            .longPressTip(chipHelp(type, index: index, stats: stats))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(member.map { "\(type.name) (\($0.name))" } ?? type.name)
            .accessibilityValue(CalendarText.workdays(stats.workdays))
            .accessibilityAddTraits(store.readOnly ? [] : .isButton)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityAction { toggle(type) }
    }

    private func toggle(_ type: CalendarEntryType) {
        guard !store.readOnly else { return }
        store.toggleOnSelection(type.id)
    }

    /// "Holiday (Anna) – Vacation: 12 days in 2026, 9 workdays", on the Mac with how to toggle it.
    private func chipHelp(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> String {
        let name = store.member(of: type).map { "\(type.name) (\($0.name))" } ?? type.name
        var text = String(localized: "\(name) – \(type.role.title): \(CalendarText.days(stats.days)) in \(String(store.year)), \(CalendarText.workdays(stats.workdays))")
        if Self.tipsHover && !store.readOnly && index < 9 {
            text += "\n" + String(localized: "Click (or press \(index + 1)) to toggle it on the selected days")
        }
        return text
    }

    /// Whether the tip shows on hover (the Mac), where it says how to toggle; elsewhere a long
    /// press shows it, after which one knows. (Not `#if`: the iOS build extracts the strings.)
    #if os(macOS)
    private static let tipsHover = true
    #else
    private static let tipsHover = false
    #endif
}

/// The year's types as a legend under the grid, wrapping: each its badge and name, by member (in
/// the household's order, nobody's last). A click highlights the type (its days stand out, the
/// others fade: `CalendarStore.highlight`), again ends it, another switches; ⌘- or ⇧-click (or the
/// item's menu) adds it to the highlight. Clear (or Esc, which the calendar handles) ends it.
/// It reads only the types, members and highlight, so hovering redraws nothing but an item.
struct CalendarLegend: View {
    let store: CalendarStore

    var body: some View {
        let types = Self.ordered(store.types, members: store.members)
        if !types.isEmpty {
            let highlight = store.activeHighlight
            RecipeFlowLayout(spacing: 6) {
                ForEach(types) { type in
                    CalendarLegendItem(store: store, type: type, member: store.member(of: type),
                                       on: highlight.contains(type.id), anyOn: !highlight.isEmpty)
                }
                if !highlight.isEmpty {
                    Button {
                        store.clearHighlight()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .frame(minHeight: 26)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Show all days alike (Esc)")
                    .accessibilityLabel(Text("Clear highlight"))
                }
            }
            .animation(.snappy(duration: 0.2), value: highlight)
            .onKeyPress(.escape) { store.clearHighlight() ? .handled : .ignored }
        }
    }

    /// The types by member, in the order of `members` (the household's), each member's in the
    /// types' order; nobody's (or a member who's gone) last.
    static func ordered(_ types: [CalendarEntryType], members: [CalendarMember]) -> [CalendarEntryType] {
        let rank = Dictionary(members.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        return types.enumerated()
            .sorted { a, b in
                let ra = a.element.memberId.flatMap { rank[$0] } ?? Int.max
                let rb = b.element.memberId.flatMap { rank[$0] } ?? Int.max
                return (ra, a.offset) < (rb, b.offset)
            }
            .map(\.element)
    }
}

/// One type of the legend: a toggle of its highlight. Its own view, so its hover state redraws it alone.
private struct CalendarLegendItem: View {
    let store: CalendarStore
    let type: CalendarEntryType
    let member: CalendarMember?
    let on: Bool
    /// Some type is highlighted: the others' items step back too.
    let anyOn: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        let color = CalendarTypeColor(type.color, scheme: scheme).fill
        let label = member.map { "\(type.name) (\($0.name))" } ?? type.name
        Button {
            let keys = CalendarModifiers.current
            store.highlight(type.id, adding: keys.contains(.command) || keys.contains(.shift))
        } label: {
            HStack(spacing: 5) {
                CalendarTypeBadge(type: type, member: member, size: 16, help: false)
                Text(type.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.leading, 4)
            .padding(.trailing, 8)
            .frame(minHeight: 26)
            .background(on ? color.opacity(0.28) : Color.primary.opacity(hovering ? 0.08 : 0), in: .capsule)
            .overlay(Capsule().strokeBorder(on ? color : .clear, lineWidth: 1.5))
            .opacity(anyOn && !on ? 0.55 : 1)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .hoverEffect()
        #endif
        .onHover { hovering = $0 }
        .help(Self.help(label))
        .contextMenu {
            if anyOn && !on {
                Button("Highlight Too", systemImage: "plus.circle") { store.highlight(type.id, adding: true) }
            } else if on && store.activeHighlight.count > 1 {
                Button("Stop Highlighting", systemImage: "minus.circle") { store.highlight(type.id, adding: true) }
            }
        }
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Highlights its days"))
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityAction(named: Text(on ? "Stop Highlighting" : "Highlight Too")) {
            store.highlight(type.id, adding: true)
        }
    }

    /// The name and member, on the Mac with how to highlight several. (Not `#if` around the
    /// string: the iOS build extracts the strings.)
    private static func help(_ label: String) -> String {
        #if os(macOS)
        let mac = true
        #else
        let mac = false
        #endif
        return mac ? label + "\n" + String(localized: "⌘-click to highlight several types") : label
    }
}

/// "No entry types for 2027 yet", with copying from the closest year.
struct CalendarEmptyTypes: View {
    @Environment(FamilyContext.self) private var family
    let store: CalendarStore

    var body: some View {
        HStack(spacing: 10) {
            Text(store.typesReadOnly ? LocalizedStringKey("No entry types for \(String(store.year)).") : LocalizedStringKey("No entry types for \(String(store.year)) yet."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !store.typesReadOnly {
                if let source = store.copySource {
                    Button("Copy types from \(String(source))") {
                        perform { try await store.copyTypes(from: source) }
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Start \(String(store.year)) with the types of \(String(source)); you can change them afterwards")
                } else {
                    Button("Add types") { family.open(.settings(.calendar)) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

/// Weekdays that need cover but have none, as a pill with a jump to the next one.
struct CalendarCoveragePill: View {
    let store: CalendarStore
    var onJump: (Day) -> Void = { _ in }

    var body: some View {
        let needs = store.needsCoverTypes
        if !needs.isEmpty {
            let gaps = store.gapDays
            let names = needs.map(\.name).joined(separator: " / ")
            HStack(spacing: 8) {
                if gaps.isEmpty {
                    Label("All covered", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(CalendarText.plural("^[\(gaps.count) uncovered weekday](inflect: true)"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button {
                        if let day = store.nextGap() { onJump(day) }
                    } label: {
                        Label("Next gap", systemImage: "arrow.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Jump to the next uncovered day (G)")
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.leading, 12)
            .padding(.trailing, gaps.isEmpty ? 12 : 4)
            .padding(.vertical, 4)
            .background((gaps.isEmpty ? Color.green : Color.red).opacity(0.12), in: .capsule)
            .help(gaps.isEmpty
                  ? String(localized: "All “\(names)” days in \(String(store.year)) are covered")
                  : String(localized: "\(CalendarText.weekdays(gaps.count)) with “\(names)” not covered yet"))
        }
    }
}

/// The year switcher: arrows around a menu of years.
struct CalendarYearSwitcher: View {
    let store: CalendarStore

    var body: some View {
        let now = Day.today.year
        let years = Array(Set(Array((now - 5)...(now + 5)) + [store.year])).sorted()
        HStack(spacing: 2) {
            Button {
                store.setYear(store.year - 1)
            } label: {
                Label("Previous year", systemImage: "chevron.left")
            }
            .help("Previous year (Page Up)")
            Menu {
                Picker("Year", selection: Binding(get: { store.year }, set: { store.setYear($0) })) {
                    ForEach(years, id: \.self) { Text(verbatim: String($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(verbatim: String(store.year))
                    .font(.headline.monospacedDigit())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                store.setYear(store.year + 1)
            } label: {
                Label("Next year", systemImage: "chevron.right")
            }
            .help("Next year (Page Down)")
        }
        .labelStyle(.iconOnly)
    }
}

/// A short message floating at the bottom (copied, nothing to undo…), with Undo after a
/// change that can be undone (a deleted event).
struct CalendarToast: View {
    let store: CalendarStore

    var body: some View {
        Group {
            if let text = store.toast {
                HStack(spacing: 12) {
                    Text(text).font(.callout)
                    if store.toastOffersUndo && store.canUndo {
                        Button("Undo") { store.performUndo() }
                            .font(.callout.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: store.toast)
    }
}
