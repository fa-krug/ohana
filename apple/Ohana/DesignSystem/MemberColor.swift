import ImageIO
import SwiftUI
import UniformTypeIdentifiers

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

/// The initials of a name in a round badge, or the member's profile picture over them (the
/// initials show while it loads and when it can't); grows with Dynamic Type. Small ones (under 20
/// points) show the first initial only.
struct FamilyAvatar: View {
    let name: String
    var tint: Color
    /// The member's photo as the server sends it (`MemberPhoto.path`); nil: the initials.
    var photo: String?
    @ScaledMetric private var size: CGFloat

    init(name: String, tint: Color = .ohana, photo: String? = nil, size: CGFloat = 32) {
        self.name = name
        self.tint = tint
        self.photo = photo
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
            .overlay {
                // Only with a photo: `RemoteImage` needs the app's model in the environment.
                if let path = MemberPhoto.path(photo) {
                    RemoteImage(path: path) { Color.clear }
                        .frame(width: size, height: size)
                        .clipShape(.circle)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A member's profile picture: where the server keeps it, and how the app prepares one to upload.
nonisolated enum MemberPhoto {
    /// The longest side of an uploaded photo, in pixels (the server crops the centre square).
    static let maxPixels = 1024

    /// The server path of a member's photo (served to the family's members only); nil for none.
    static func path(_ photo: String?) -> String? {
        guard let photo, !photo.isEmpty else { return nil }
        return "/api/images/\(photo)"
    }

    /// A picked image (JPEG, PNG, HEIC, …) as a JPEG of at most `maxPixels` on its longest side,
    /// upright and drawn onto white (transparency would turn black); nil if it isn't an image.
    static func jpeg(from data: Data, maxPixels: Int = maxPixels, quality: Double = 0.85) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

/// A member as an icon only: their avatar (photo or initials) in their color, small, the name on
/// hover, a long press and for VoiceOver. Where there is no room for the name (a type's chip, a
/// row of the overview).
struct MemberIcon: View {
    let name: String
    /// The member's color key.
    let color: String?
    /// The member's photo (`MemberPhoto.path`).
    var photo: String?
    var size: CGFloat = 18

    var body: some View {
        FamilyAvatar(name: name, tint: MemberColor.color(color), photo: photo, size: size)
            .longPressTip(name)
            .accessibilityElement()
            .accessibilityLabel(Text(name))
    }
}
