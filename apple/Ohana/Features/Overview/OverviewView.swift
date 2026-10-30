import SwiftUI

/// Overview (placeholder until the module is ported).
struct OverviewView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Overview", systemImage: "square.grid.2x2")
            .ohanaBackground(ModuleTint.overview)
            .navigationTitle("Overview")
    }
}
