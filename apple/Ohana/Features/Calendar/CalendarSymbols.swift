import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The SF Symbols a calendar type or a day's note can have: curated lists to pick from, their
/// names in words (VoiceOver, the pickers' labels) and suggestions by a name. Types and notes store
/// the symbol's name.
enum CalendarSymbol {
    /// For types: the roles' defaults first, then what a type of days may be about.
    static let typeIcons: [String] = CalendarRole.allCases.map(\.defaultIcon) + [
        "beach.umbrella", "airplane", "suitcase", "suitcase.rolling", "house.lodge", "tent", "mountain.2", "map",
        "house", "building.2", "building.columns", "briefcase", "laptopcomputer", "graduationcap", "backpack",
        "books.vertical", "figure.and.child.holdinghands", "figure.2.and.child.holdinghands", "teddybear", "stroller",
        "person.2", "cross.case", "stethoscope", "bandage", "pills", "syringe", "thermometer.medium", "mouth",
        "bed.double", "moon.zzz", "car", "bus", "tram", "bicycle", "gift", "party.popper", "star", "heart", "flag",
        "calendar", "clock", "hourglass", "sportscourt", "figure.run", "soccerball", "figure.pool.swim",
        "figure.skiing.downhill", "music.note", "theatermasks", "paintpalette", "wrench.and.screwdriver", "shippingbox",
        "leaf", "tree", "snowflake", "pawprint",
    ]

    /// For a day's note.
    static let noteIcons: [String] = [
        "star", "heart", "gift", "birthday.cake", "party.popper", "balloon.2", "sparkles", "fireworks", "tree", "hare",
        "flame", "moon.stars", "cross", "flag", "bell", "alarm", "clock", "hourglass", "exclamationmark.circle",
        "info.circle", "questionmark.circle", "checkmark.circle", "pin", "mappin", "house", "key", "person.2",
        "person.3", "figure.and.child.holdinghands", "figure.2.and.child.holdinghands", "teddybear", "stroller",
        "car", "bus", "tram", "bicycle", "airplane", "ferry", "suitcase", "beach.umbrella", "tent", "mountain.2", "map",
        "figure.walk", "figure.run", "figure.hiking", "figure.pool.swim", "figure.skiing.downhill", "figure.yoga",
        "figure.equestrian.sports", "figure.martial.arts", "figure.socialdance", "sportscourt", "soccerball",
        "basketball", "tennis.racket", "dumbbell", "trophy", "medal", "music.note", "music.mic", "guitars",
        "pianokeys", "theatermasks", "ticket", "film", "popcorn", "gamecontroller", "puzzlepiece", "paintpalette",
        "camera", "book", "pencil", "backpack", "graduationcap", "building.columns", "briefcase", "laptopcomputer",
        "phone", "envelope", "doc.text", "cross.case", "stethoscope", "pills", "syringe", "bandage",
        "thermometer.medium", "mouth", "eye", "bed.double", "cart", "bag", "eurosign", "creditcard", "scissors",
        "tshirt", "wrench.and.screwdriver", "shippingbox", "trash", "fork.knife", "cup.and.saucer", "wineglass",
        "pawprint", "dog", "cat", "bird", "leaf", "sun.max", "cloud.rain", "umbrella", "snowflake",
    ]

    // Their names in words and the words that suggest them: `catalog`, CalendarSymbolCatalog.swift.

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

/// A type as a double icon: its member's avatar (their photo or initials, as `MemberIcon`; none
/// without a member), then the type's own symbol in a circle of the same size, filled with its
/// color. Reads "Type (Member)".
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
                FamilyAvatar(name: member.name, tint: MemberColor.color(member.color), photo: member.photo, size: baseSize)
            }
            CalendarTypeIcon(color: color, icon: icon, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel(Text(label))
    }
}

/// A type's symbol alone: white (or black on a light color) in a circle of its color, as the days
/// draw it (`CalendarTypeColor`: a gray darker in dark mode).
struct CalendarTypeIcon: View {
    let color: String
    let icon: String
    let size: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let look = CalendarTypeColor(color, scheme: scheme)
        Image(systemName: CalendarSymbol.drawable(icon, fallback: "tag") ?? "tag")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(look.ink)
            .frame(width: size, height: size)
            .background(look.fill.gradient, in: .circle)
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
/// `suggested` (`CalendarSymbol.suggestions`, by the name or comment) come first in a row of their own.
struct CalendarSymbolGrid: View {
    let symbols: [String]
    @Binding var selection: String
    var allowsNone = false
    var suggested: [String] = []

    private let columns = [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !suggested.isEmpty {
                Label("Suggested", systemImage: "sparkles")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(suggested, id: \.self) { name in
                        cell(name, label: CalendarSymbol.title(name), systemImage: name)
                    }
                }
                Divider()
            }
            LazyVGrid(columns: columns, spacing: 6) {
                if allowsNone {
                    cell("", label: String(localized: "No icon"), systemImage: "circle.slash")
                }
                ForEach(symbols, id: \.self) { name in
                    cell(name, label: CalendarSymbol.title(name), systemImage: name)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.snappy, value: suggested)
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
