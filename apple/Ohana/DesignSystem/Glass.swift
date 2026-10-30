import SwiftUI

/// Liquid Glass building blocks shared by the modules.
extension View {
    /// A card of glass: the content padded, on a rounded glass surface.
    func glassCard(cornerRadius: CGFloat = 24, padding: CGFloat = 16, tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(glass(tint: tint, interactive: interactive), in: .rect(cornerRadius: cornerRadius))
    }

    /// A capsule of glass, for chips and small badges.
    func glassChip(tint: Color? = nil, interactive: Bool = false) -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(glass(tint: tint, interactive: interactive), in: .capsule)
    }
}

private func glass(tint: Color?, interactive: Bool) -> Glass {
    var g = Glass.regular
    if let tint { g = g.tint(tint.opacity(0.35)) }
    if interactive { g = g.interactive() }
    return g
}

/// A titled section of glass cards: the heading outside the glass, the content in it.
struct GlassSection<Content: View, Accessory: View>: View {
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
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 12) { content }
                .glassCard(tint: nil)
        }
    }
}

/// A round glass icon in a module's tint: the leading icon of rows and cards.
struct TintedIcon: View {
    let systemImage: String
    var tint: Color = .ohana
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .circle)
    }
}
