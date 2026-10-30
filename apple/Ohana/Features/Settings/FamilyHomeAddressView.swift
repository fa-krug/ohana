import MapKit
import SwiftUI

/// Settings → Home address: where the family lives (geocoded with Photon through the server's
/// /geocode), the origin of the distances on the appointment pages.
struct FamilyHomeAddressView: View {
    @Environment(FamilyContext.self) private var family
    let model: FamilySettingsModel

    @State private var query = ""
    @State private var suggestions: [FamilyLocationSuggestion] = []
    @State private var searching = false
    @State private var confirmClear = false

    var body: some View {
        Group {
            if let household = model.household {
                form(household)
            } else {
                ProgressView()
            }
        }
        .ohanaBackground(ModuleTint.settings)
        .navigationTitle("Home address")
        .task(id: query) { await search() }
    }

    private func form(_ household: FamilyHousehold) -> some View {
        Form {
            Section {
                if let address = household.home.address {
                    Label(address, systemImage: "house.fill")
                    if let lat = household.home.lat, let lng = household.home.lng {
                        FamilyHomeMap(address: address, coordinate: .init(latitude: lat, longitude: lng))
                            .frame(height: 180)
                            .clipShape(.rect(cornerRadius: 16))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        Text(verbatim: String(format: "%.5f, %.5f", lat, lng))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Not set.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Where the family lives: appointments show how far a practice is from here.")
            }

            if household.canEdit {
                Section("Search") {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Street, ZIP city", text: $query)
                            .autocorrectionDisabled()
                            .textContentType(.fullStreetAddress)
                        if searching { ProgressView().controlSize(.small) }
                    }
                    ForEach(suggestions) { suggestion in
                        Button {
                            choose(suggestion)
                        } label: {
                            Label(suggestion.label, systemImage: "mappin.and.ellipse")
                                .foregroundStyle(.primary)
                        }
                    }
                }
                if household.home.address != nil {
                    Section {
                        Button("Remove home address", role: .destructive) { confirmClear = true }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .confirmationDialog("Remove the home address?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { save(FamilyHomeInput(address: "", lat: nil, lng: nil)) }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 3 else {
            suggestions = []
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
            searching = true
            defer { searching = false }
            suggestions = try await family.api.get("/geocode", query: ["q": text])
        } catch is CancellationError {
        } catch {
            suggestions = []
        }
    }

    private func choose(_ suggestion: FamilyLocationSuggestion) {
        guard let lat = Double(suggestion.latitude), let lng = Double(suggestion.longitude) else { return }
        query = ""
        suggestions = []
        save(FamilyHomeInput(address: suggestion.label, lat: lat, lng: lng))
    }

    private func save(_ input: FamilyHomeInput) {
        let api = family.api
        model.change(family) {
            try await api.perform(.put, "/household/home", body: input)
        }
    }
}

/// A small map with the home's pin.
private struct FamilyHomeMap: View {
    let address: String
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                       latitudinalMeters: 1500, longitudinalMeters: 1500)),
            interactionModes: []) {
            Marker(address, systemImage: "house.fill", coordinate: coordinate)
                .tint(Color.ohana)
        }
        .id("\(coordinate.latitude),\(coordinate.longitude)")
        .accessibilityLabel(Text(address))
    }
}
