import SwiftUI

/// The surfaces of the content layer. Liquid Glass belongs to the controls and navigation that
/// float above the content (bars, toolbars, floating buttons, banners); content sits on these
/// solid, system-colored cards instead, so it stays legible in light, dark and high contrast.
extension View {
    /// A card: the content padded, on a rounded card surface (the grouped list's cell color).
    func contentCard(cornerRadius: CGFloat = 24, padding: CGFloat = 16, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.cardBackground)
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(tint.opacity(0.12))
                        }
                    }
            }
    }

    /// A capsule for chips and small badges in the content.
    func chip(tint: Color? = nil) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background((tint ?? .secondary).opacity(tint == nil ? 0.15 : 0.18), in: .capsule)
    }
}

extension View {
    /// An icon button's label or a chip in a row: at least 44×44 pt to hit on iPhone and iPad;
    /// the Mac keeps its compact rows. Goes on the button's label, where it widens what's hit.
    func rowHitTarget() -> some View {
        #if os(iOS)
        frame(minWidth: 44, minHeight: 44).contentShape(.rect)
        #else
        self
        #endif
    }
}

extension Color {
    /// A card on the page's background: the grouped list's cell color. On the Mac in dark mode
    /// the control background is the window's own gray, so the card is a step lighter there.
    static var cardBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: macCardBackground)
        #endif
    }

    #if os(macOS)
    private static let macCardBackground = NSColor(name: "ohanaCardBackground") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                           .accessibilityHighContrastDarkAqua]) {
        case .darkAqua: NSColor(white: 0.17, alpha: 1)
        case .accessibilityHighContrastDarkAqua: NSColor(white: 0.2, alpha: 1)
        default: .controlBackgroundColor
        }
    }
    #endif

    /// The page behind cards and grouped lists.
    static var pageBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}

/// A titled section of cards: the heading outside the card, the content in it.
struct CardSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    var tint: Color?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: LocalizedStringKey, systemImage: String? = nil, tint: Color? = nil,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .foregroundStyle(tint ?? .primary)
                } else {
                    Text(title)
                }
                Spacer()
                accessory
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .contentCard()
        }
    }
}

/// A round icon in a module's tint: the leading icon of rows and cards. Grows with Dynamic Type.
struct TintedIcon: View {
    let systemImage: String
    var tint: Color = .ohana
    @ScaledMetric private var size: CGFloat

    init(systemImage: String, tint: Color = .ohana, size: CGFloat = 34) {
        self.systemImage = systemImage
        self.tint = tint
        _size = ScaledMetric(wrappedValue: size, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Keeps a list's or form's rows to a readable column (760 pt, as the meal plan and the slot
    /// page) on a wide window, iPad and Mac: the margins beside the rows grow, while the list,
    /// its scroll bar and the page's background still fill the page. Narrower, the system's
    /// margins stay.
    func readableWidth(_ maxWidth: CGFloat = 760) -> some View {
        modifier(ReadableWidth(maxWidth: maxWidth))
    }
}

private struct ReadableWidth: ViewModifier {
    let maxWidth: CGFloat
    /// The margin on each side; nil (the system's) until the page is wide enough to need one.
    /// Only changes past `maxWidth`, so a narrow page never updates it while it's resized.
    @State private var margin: CGFloat?

    func body(content: Content) -> some View {
        let maxWidth = maxWidth
        content
            #if os(macOS)
            // The Mac's lists ignore content margins; both they and forms take the padding
            // (on top of their own margins).
            .safeAreaPadding(.horizontal, margin ?? 0)
            #else
            .contentMargins(.horizontal, margin, for: .scrollContent)
            #endif
            .onGeometryChange(for: CGFloat?.self) { proxy in
                ReadableWidth.margin(width: proxy.size.width, maxWidth: maxWidth)
            } action: { margin = $0 }
    }

    nonisolated static func margin(width: CGFloat, maxWidth: CGFloat) -> CGFloat? {
        let side = ((width - maxWidth) / 2).rounded()
        return side > 24 ? side : nil
    }
}
