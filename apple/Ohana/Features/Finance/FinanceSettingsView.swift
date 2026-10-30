import SwiftUI

/// Settings → Finance: currency, categories, accounts, CSV mappings (placeholder until the module is ported).
struct FinanceSettingsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Finance", systemImage: "banknote")
            .navigationTitle("Finance")
    }
}
