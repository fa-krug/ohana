import SwiftUI

/// Settings (placeholder until the module is ported).
struct FamilySettingsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Settings", systemImage: "gearshape")
            .ohanaBackground(ModuleTint.settings)
            .navigationTitle("Settings")
    }
}
