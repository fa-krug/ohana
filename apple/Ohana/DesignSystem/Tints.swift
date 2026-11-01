import SwiftUI

// Shared with the widgets (OhanaWidgets).

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
