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
