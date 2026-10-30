import SwiftUI

extension Color {
    /// Ohana's teal (the web app's `--primary`, #0d9488); the asset catalog's AccentColor too.
    static let ohana = Color(red: 13 / 255, green: 148 / 255, blue: 136 / 255)
}

/// The modules' colors, used for their icons and accents throughout.
enum ModuleTint {
    static let overview = Color.ohana
    static let calendar = Color.blue
    static let finance = Color.green
    static let meals = Color.orange
    static let appointments = Color.pink
    static let assistant = Color.purple
    static let settings = Color.gray
}

/// The soft backdrop behind the app's pages: it gives the Liquid Glass surfaces something to
/// refract. Adapts to light and dark.
struct OhanaBackground: View {
    var tint: Color = .ohana
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(white: scheme == .dark ? 0.06 : 0.97)
            LinearGradient(
                colors: [tint.opacity(scheme == .dark ? 0.28 : 0.18), .clear],
                startPoint: .topLeading, endPoint: .center
            )
            RadialGradient(
                colors: [Color.ohana.opacity(scheme == .dark ? 0.18 : 0.10), .clear],
                center: .bottomTrailing, startRadius: 20, endRadius: 600
            )
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
