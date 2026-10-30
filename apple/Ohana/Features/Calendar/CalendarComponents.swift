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

    /// The color as "#rrggbb" (sRGB), for the server.
    func calendarHex(in environment: EnvironmentValues = EnvironmentValues()) -> String {
        let cg = resolve(in: environment).cgColor
        if let srgb = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = cg.converted(to: srgb, intent: .defaultIntent, options: nil),
           let c = converted.components, c.count >= 3 {
            return CalendarMath.hex(r: Double(c[0]), g: Double(c[1]), b: Double(c[2]))
        }
        return "#64748b"
    }
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

    static func days(_ n: Int) -> String { String(localized: "\(n) days") }

    /// "5 days selected (3 weekdays): Mon 3 Mar – Fri 7 Mar".
    static func selection(_ days: [Day]) -> String {
        let work = days.filter { !CalendarMath.isWeekend($0) }.count
        return String(localized: "\(days.count) days selected (\(work) weekdays): \(span(days))")
    }

    /// Weekday letters in the order of the device's week (`firstWeekday`).
    static var weekdayLetters: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
    }
}

/// The colors of a day's entry types as side-by-side bands (the web grid's fills).
struct CalendarFills: View {
    let types: [CalendarEntryType]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(types) { type in
                Color(calendarHex: type.color)
                    .overlay {
                        if type.role == .needsCover {
                            // "Needs cover" days are striped, like the web's.
                            CalendarStripes().opacity(0.25)
                        }
                    }
            }
        }
    }
}

struct CalendarStripes: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            let step: CGFloat = 6
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            ctx.stroke(path, with: .color(.white), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// A type's swatch.
struct CalendarSwatch: View {
    let type: CalendarEntryType
    var size: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: size / 4)
            .fill(Color(calendarHex: type.color))
            .overlay {
                if type.role == .needsCover {
                    CalendarStripes().opacity(0.4).clipShape(.rect(cornerRadius: size / 4))
                }
            }
            .frame(width: size, height: size)
    }
}

/// The year's types as toggle chips with their workday counts; on the selection they add or
/// remove the type. A year without types offers to copy them from another year.
struct CalendarTypeChips: View {
    @Bindable var store: CalendarStore
    var showEditLink = true

    var body: some View {
        if store.types.isEmpty {
            if store.typeYears != nil { CalendarEmptyTypes(store: store) }
        } else {
            let stats = store.stats
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        ForEach(Array(store.types.enumerated()), id: \.element.id) { index, type in
                            chip(type, index: index, stats: stats[type.id] ?? CalendarTypeStats())
                        }
                        if showEditLink && !store.readOnly {
                            NavigationLink {
                                CalendarSettingsView()
                            } label: {
                                Image(systemName: "pencil")
                                    .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Edit types")
                            .accessibilityLabel("Edit types")
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func chip(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> some View {
        let active = store.selectionHas(type.id)
        let color = Color(calendarHex: type.color)
        return Button {
            store.toggleOnSelection(type.id)
        } label: {
            HStack(spacing: 6) {
                CalendarSwatch(type: type, size: 12)
                Text(type.name).lineLimit(1)
                Text("\(stats.workdays)d")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(active ? color.opacity(0.45) : .clear).interactive(), in: .capsule)
        .disabled(store.readOnly)
        .help(chipHelp(type, index: index, stats: stats))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func chipHelp(_ type: CalendarEntryType, index: Int, stats: CalendarTypeStats) -> String {
        var text = String(localized: "\(type.name) – \(type.role.title): \(stats.days) days in \(String(store.year)), \(stats.workdays) workdays")
        if !store.readOnly && index < 9 {
            text += "\n" + String(localized: "Click (or press \(index + 1)) to toggle it on the selected days")
        }
        return text
    }
}

/// "No entry types for 2027 yet", with copying from the closest year.
struct CalendarEmptyTypes: View {
    let store: CalendarStore

    var body: some View {
        HStack(spacing: 10) {
            Text(store.readOnly ? LocalizedStringKey("No entry types for \(String(store.year)).") : LocalizedStringKey("No entry types for \(String(store.year)) yet."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !store.readOnly {
                if let source = store.copySource {
                    Button("Copy types from \(String(source))") {
                        perform { try await store.copyTypes(from: source) }
                    }
                    .buttonStyle(.glassProminent)
                } else {
                    NavigationLink("Add types") { CalendarSettingsView() }
                        .buttonStyle(.glassProminent)
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
                    Label("\(gaps.count) uncovered weekdays", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button {
                        if let day = store.nextGap() { onJump(day) }
                    } label: {
                        Label("Next gap", systemImage: "arrow.right")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .help("Jump to the next uncovered day (G)")
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            .padding(.leading, 12)
            .padding(.trailing, gaps.isEmpty ? 12 : 4)
            .padding(.vertical, 4)
            .glassEffect(.regular.tint((gaps.isEmpty ? Color.green : Color.red).opacity(0.12)), in: .capsule)
            .help(gaps.isEmpty
                  ? String(localized: "All “\(names)” days in \(String(store.year)) are covered")
                  : String(localized: "\(gaps.count) weekdays with “\(names)” not covered yet"))
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

/// A short message floating at the bottom (copied, nothing to undo…).
struct CalendarToast: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let text {
                Text(text)
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: text)
    }
}
