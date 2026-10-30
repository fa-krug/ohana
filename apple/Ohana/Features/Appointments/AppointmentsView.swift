import SwiftUI

/// Appointments (placeholder until the module is ported).
struct AppointmentsView: View {
    @Environment(FamilyContext.self) private var family

    var body: some View {
        ContentUnavailableView("Appointments", systemImage: "stethoscope")
            .ohanaBackground(ModuleTint.appointments)
            .navigationTitle("Appointments")
    }
}
