import SwiftUI

/// The backdrop behind the app's pages: the system's grouped background with a faint wash of
/// the module's color at the top. Adapts to light, dark and Increase Contrast (no wash then).
struct OhanaBackground: View {
    var tint: Color = .ohana
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color.pageBackground
            if contrast == .standard {
                LinearGradient(
                    colors: [tint.opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                    startPoint: .top, endPoint: .center
                )
            }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// The page backdrop (`OhanaBackground`) behind a scroll view or list.
    func ohanaBackground(_ tint: Color = .ohana) -> some View {
        background { OhanaBackground(tint: tint) }
            .scrollContentBackground(.hidden)
    }
}

/// The app's mark: a house on the Ohana gradient (the connect sheet, the loading screen).
struct OhanaLogo: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "house.fill")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.ohana.gradient, in: .rect(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}
