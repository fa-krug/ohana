import SwiftUI

/// A family member's color (accounts and people alike): one of a fixed palette, sent by its key
/// (server/lib/families/colors.ts). Their calendar types' colors come from it; elsewhere it tints
/// their avatar. In the server's order, which is also the order new members get them in.
enum MemberColor: String, CaseIterable, Identifiable {
    case blue, orange, green, red, purple, yellow, teal, pink, indigo, brown

    var id: String { rawValue }

    /// The key's color; nil for an unknown one.
    init?(key: String?) {
        guard let key, let color = MemberColor(rawValue: key) else { return nil }
        self = color
    }

    var hex: String {
        switch self {
        case .blue: "#0090ff"
        case .orange: "#f76b15"
        case .green: "#30a46c"
        case .red: "#e5484d"
        case .purple: "#8e4ec6"
        case .yellow: "#f2b705"
        case .teal: "#12a594"
        case .pink: "#d6409f"
        case .indigo: "#3e63dd"
        case .brown: "#8a5a3c"
        }
    }

    var color: Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    var name: String {
        switch self {
        case .blue: String(localized: "Blue")
        case .orange: String(localized: "Orange")
        case .green: String(localized: "Green")
        case .red: String(localized: "Red")
        case .purple: String(localized: "Purple")
        case .yellow: String(localized: "Yellow")
        case .teal: String(localized: "Teal")
        case .pink: String(localized: "Pink")
        case .indigo: String(localized: "Indigo")
        case .brown: String(localized: "Brown")
        }
    }

    /// The color of a key as sent; gray for none or an unknown one.
    static func color(_ key: String?) -> Color {
        MemberColor(key: key)?.color ?? .gray
    }
}

/// The initials of a name in a round badge; grows with Dynamic Type. Small ones (under 20 points)
/// show the first initial only.
struct FamilyAvatar: View {
    let name: String
    var tint: Color
    @ScaledMetric private var size: CGFloat

    init(name: String, tint: Color = .ohana, size: CGFloat = 32) {
        self.name = name
        self.tint = tint
        _size = ScaledMetric(wrappedValue: size, relativeTo: .caption)
    }

    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "@" || $0 == "." }).prefix(size < 20 ? 1 : 2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * (size < 20 ? 0.55 : 0.4), weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

/// A member as an icon only: their avatar in their color, small, the name on hover and for
/// VoiceOver. Where there is no room for the name (a type's chip, a row of the overview).
struct MemberIcon: View {
    let name: String
    /// The member's color key.
    let color: String?
    var size: CGFloat = 18

    var body: some View {
        FamilyAvatar(name: name, tint: MemberColor.color(color), size: size)
            .help(name)
            .accessibilityElement()
            .accessibilityLabel(Text(name))
    }
}
