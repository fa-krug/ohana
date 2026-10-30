import SwiftUI

/// Finance (placeholder until the module is ported).
struct FinanceView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Finance", systemImage: "banknote")
            .ohanaBackground(ModuleTint.finance)
            .navigationTitle("Finance")
    }
}
