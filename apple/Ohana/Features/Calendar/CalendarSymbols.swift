import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The SF Symbols a calendar type or a day's note can have: curated lists to pick from, and their
/// names in words (VoiceOver, the pickers' labels). Types and notes store the symbol's name.
enum CalendarSymbol {
    /// For types: the roles' defaults first, then what a type of days may be about.
    static let typeIcons: [String] = CalendarRole.allCases.map(\.defaultIcon) + [
        "beach.umbrella", "airplane", "suitcase", "house", "building.2", "briefcase", "graduationcap", "backpack",
        "figure.and.child.holdinghands", "cross.case", "bandage", "pills", "thermometer.medium", "stethoscope",
        "bed.double", "car", "tram", "gift", "party.popper", "star", "heart", "flag", "calendar", "books.vertical",
        "sportscourt", "music.note", "leaf", "snowflake", "pawprint",
    ]

    /// For a day's note.
    static let noteIcons: [String] = [
        "star", "heart", "gift", "birthday.cake", "party.popper", "flag", "bell", "exclamationmark.circle",
        "info.circle", "pin", "house", "car", "airplane", "tram", "figure.walk", "figure.run", "sportscourt",
        "soccerball", "music.note", "book", "graduationcap", "briefcase", "cross.case", "pills", "stethoscope",
        "cart", "fork.knife", "camera", "pawprint", "leaf", "sun.max", "snowflake",
    ]

    /// The symbol's name in words; for one not in the lists its name, readable.
    static func title(_ name: String) -> String {
        switch name {
        case "tag": String(localized: "Tag")
        case "exclamationmark.triangle": String(localized: "Warning")
        case "checkmark.shield": String(localized: "Shield")
        case "sun.max": String(localized: "Sun")
        case "beach.umbrella": String(localized: "Beach umbrella")
        case "airplane": String(localized: "Airplane")
        case "suitcase": String(localized: "Suitcase")
        case "house": String(localized: "House")
        case "building.2": String(localized: "Office")
        case "briefcase": String(localized: "Briefcase")
        case "graduationcap": String(localized: "Graduation cap")
        case "backpack": String(localized: "Backpack")
        case "figure.and.child.holdinghands": String(localized: "Adult and child")
        case "cross.case": String(localized: "First aid kit")
        case "bandage": String(localized: "Bandage")
        case "pills": String(localized: "Pills")
        case "thermometer.medium": String(localized: "Thermometer")
        case "stethoscope": String(localized: "Stethoscope")
        case "bed.double": String(localized: "Bed")
        case "car": String(localized: "Car")
        case "tram": String(localized: "Train")
        case "gift": String(localized: "Gift")
        case "party.popper": String(localized: "Party")
        case "star": String(localized: "Star")
        case "heart": String(localized: "Heart")
        case "flag": String(localized: "Flag")
        case "calendar": String(localized: "Calendar")
        case "books.vertical": String(localized: "Books")
        case "sportscourt": String(localized: "Sports")
        case "music.note": String(localized: "Music")
        case "leaf": String(localized: "Leaf")
        case "snowflake": String(localized: "Snowflake")
        case "pawprint": String(localized: "Paw print")
        case "birthday.cake": String(localized: "Birthday cake")
        case "bell": String(localized: "Bell")
        case "exclamationmark.circle": String(localized: "Important")
        case "info.circle": String(localized: "Info")
        case "pin": String(localized: "Pin")
        case "figure.walk": String(localized: "Walk")
        case "figure.run": String(localized: "Run")
        case "soccerball": String(localized: "Football")
        case "book": String(localized: "Reading")
        case "cart": String(localized: "Shopping")
        case "fork.knife": String(localized: "Meal")
        case "camera": String(localized: "Camera")
        default: name.replacingOccurrences(of: ".", with: " ")
        }
    }

    private static var known: [String: Bool] = [:]

    /// Whether the system has a symbol of that name (a server may send one this OS doesn't know).
    static func exists(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if let found = known[name] { return found }
        #if canImport(UIKit)
        let found = UIImage(systemName: name) != nil
        #else
        let found = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #endif
        known[name] = found
        return found
    }

    /// The symbol to draw for a stored name: itself when the system has it, else `fallback`.
    static func drawable(_ name: String, fallback: String? = nil) -> String? {
        exists(name) ? name : fallback
    }
}

/// A type as a double icon: its member's initials (`MemberIcon`; none without a member), then the
/// type's own symbol in a circle of the same size, filled with its color. Reads "Type (Member)".
struct CalendarTypeBadge: View {
    let name: String
    /// "#rrggbb".
    let color: String
    let icon: String
    let member: CalendarMember?
    /// Whether it gives its label as help (off where the view around it has a longer one).
    var help = true
    @ScaledMetric private var size: CGFloat
    private let baseSize: CGFloat

    init(name: String, color: String, icon: String, member: CalendarMember?, size: CGFloat = 18, help: Bool = true) {
        self.name = name
        self.color = color
        self.icon = icon
        self.member = member
        self.help = help
        baseSize = size
        // As `FamilyAvatar`, so both circles match.
        _size = ScaledMetric(wrappedValue: size, relativeTo: .caption)
    }

    init(type: CalendarEntryType, member: CalendarMember?, size: CGFloat = 18, help: Bool = true) {
        self.init(name: type.name, color: type.color, icon: type.icon, member: member, size: size, help: help)
    }

    var label: String { member.map { "\(name) (\($0.name))" } ?? name }

    var body: some View {
        if help {
            icons.help(label)
        } else {
            icons
        }
    }

    private var icons: some View {
        HStack(spacing: max(2, size * 0.12)) {
            if let member {
                FamilyAvatar(name: member.name, tint: MemberColor.color(member.color), size: baseSize)
            }
            CalendarTypeIcon(color: color, icon: icon, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
    }
}

/// A type's symbol alone: white (or black on a light color) in a circle of its color.
struct CalendarTypeIcon: View {
    let color: String
    let icon: String
    let size: CGFloat

    var body: some View {
        Image(systemName: CalendarSymbol.drawable(icon, fallback: "tag") ?? "tag")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(CalendarMath.prefersDarkText(on: color) ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(Color(calendarHex: color).gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A note's symbol in the theme color; nothing for none (or one the system doesn't have).
struct CalendarNoteSymbol: View {
    let icon: String

    var body: some View {
        if let name = CalendarSymbol.drawable(icon) {
            Image(systemName: name)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text(CalendarSymbol.title(name)))
        }
    }
}

/// A grid of symbols to pick one from, the chosen one filled in the theme color and checked.
/// With `allowsNone`, a first cell clears the choice (`""`), and tapping the chosen one does too.
struct CalendarSymbolGrid: View {
    let symbols: [String]
    @Binding var selection: String
    var allowsNone = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: 6)], spacing: 6) {
            if allowsNone {
                cell("", label: String(localized: "No icon"), systemImage: "circle.slash")
            }
            ForEach(symbols, id: \.self) { name in
                cell(name, label: CalendarSymbol.title(name), systemImage: name)
            }
        }
        .padding(.vertical, 4)
    }

    private func cell(_ name: String, label: String, systemImage: String) -> some View {
        let selected = selection == name
        return Button {
            selection = allowsNone && selected ? "" : name
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(selected ? Color.white : (name.isEmpty ? Color.secondary : Color.accentColor))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: .rect(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.accentColor, Color.white)
                            .padding(3)
                    }
                }
                .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
