import MapKit
import SwiftUI

/// One slot (slot-detail.tsx): the doctor, time, practice and address on a map, the distance
/// from home; book on the provider's page, mark as booked (a calendar event), ignore.
struct AppointmentSlotView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let searchID: String
    let resultID: Int
    @State private var state: LoadState<AppointmentSlotDetail> = .idle
    @State private var booking = false
    @State private var confirmRemove = false

    var body: some View {
        LoadStateView(state: state, retry: load) { detail in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(detail)
                    if let coordinate = detail.slot.coordinate {
                        map(detail, coordinate)
                    }
                    facts(detail)
                    if let booked = detail.booking {
                        bookedCard(booked)
                    }
                    actions(detail)
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .ohanaBackground(ModuleTint.appointments)
        .navigationTitle(state.value?.slot.doctorName ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: [family.revision(.appointments), family.revision(.events)]) { await load() }
        .sheet(isPresented: $booking) {
            if let detail = state.value {
                AppointmentBookSheet(detail: detail) { await load() }
            }
        }
        .confirmationDialog("Remove the appointment?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                guard let eventID = state.value?.booking?.eventId else { return }
                perform { try await AppointmentActions.removeBooking(family, eventID) }
            }
        } message: {
            Text("Remove this appointment from Ohana? This doesn’t cancel it with the practice.")
        }
    }

    private func load() async {
        await LoadState.run($state) { try await family.api.get("/appointments/searches/\(searchID)/slots/\(resultID)") }
    }

    private func header(_ detail: AppointmentSlotDetail) -> some View {
        let slot = detail.slot
        return VStack(alignment: .leading, spacing: 8) {
            Text(slot.doctorName)
                .font(.title2.weight(.semibold))
            Text(AppointmentLogic.formatSlot(slot.slot, full: true))
                .font(.headline)
                .foregroundStyle(ModuleTint.appointments)
            HStack(spacing: 6) {
                Text(slot.isNextSlot ? "Next available appointment" : "Bookable appointment")
                    .font(.caption.weight(.medium))
                    .glassChip()
                Text(verbatim: slot.sourceName)
                    .font(.caption.weight(.medium))
                    .glassChip(tint: ModuleTint.appointments)
            }
            Text(detail.searchName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .glassCard()
    }

    private func map(_ detail: AppointmentSlotDetail, _ c: (lat: Double, lng: Double)) -> some View {
        let practice = CLLocationCoordinate2D(latitude: c.lat, longitude: c.lng)
        let name = detail.slot.practiceName.isEmpty ? detail.slot.doctorName : detail.slot.practiceName
        return Map(initialPosition: .region(MKCoordinateRegion(
            center: practice, latitudinalMeters: 1500, longitudinalMeters: 1500
        ))) {
            Marker(name, systemImage: "stethoscope", coordinate: practice)
                .tint(ModuleTint.appointments)
            if let lat = detail.homeLat, let lng = detail.homeLng {
                Marker("Home", systemImage: "house.fill", coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))
                    .tint(Color.ohana)
            }
        }
        .frame(height: 240)
        .clipShape(.rect(cornerRadius: 24))
        .overlay(alignment: .bottomTrailing) {
            Button("Open in Maps", systemImage: "map") {
                openURL(AppointmentLogic.mapsURL(lat: c.lat, lng: c.lng, name: name))
            }
            .buttonStyle(.glass)
            .padding(10)
        }
    }

    private func facts(_ detail: AppointmentSlotDetail) -> some View {
        let slot = detail.slot
        let unknown = String(localized: "Unknown")
        return VStack(alignment: .leading, spacing: 10) {
            fact("Title", slot.doctorSubtitle.isEmpty ? unknown : slot.doctorSubtitle)
            fact("Speciality", slot.speciality.isEmpty ? unknown : slot.speciality)
            fact("Practice", slot.practiceName.isEmpty ? unknown : slot.practiceName)
            fact("Reason for the visit", slot.motiveLabel.isEmpty ? unknown : slot.motiveLabel)
            fact("Insurance", AppointmentLogic.insuranceLabel(detail.insuranceSector))
            fact("Address", slot.address.isEmpty ? unknown : slot.address)
            if let distance = AppointmentLogic.distance(of: slot, homeLat: detail.homeLat, homeLng: detail.homeLng) {
                fact("Distance from home", distance)
            } else if detail.homeLat == nil {
                LabeledContent("Distance from home") {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("No home address yet.").foregroundStyle(.secondary)
                        Button("Set it") { Module.settings.open() }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                fact("Distance from home", unknown)
            }
        }
        .font(.subheadline)
        .glassCard()
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func bookedCard(_ booked: AppointmentBookingInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Booked for \(AppointmentLogic.formatBooking(date: booked.date, start: booked.start))")
                        .font(.headline)
                    if !booked.person.isEmpty {
                        Text(booked.person).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "calendar.badge.checkmark").foregroundStyle(.green)
            }
            HStack {
                Button("Calendar", systemImage: "calendar") { Module.calendar.open() }
                    .buttonStyle(.glass)
                if family.canEdit {
                    Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .glassCard(tint: .green)
    }

    private func actions(_ detail: AppointmentSlotDetail) -> some View {
        let slot = detail.slot
        return GlassEffectContainer(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actionButtons(detail, slot) }
                VStack(alignment: .leading, spacing: 12) { actionButtons(detail, slot) }
            }
        }
    }

    @ViewBuilder private func actionButtons(_ detail: AppointmentSlotDetail, _ slot: AppointmentDoctorSlot) -> some View {
        if let url = slot.bookingURL {
            Button("Book", systemImage: "arrow.up.right.square") { openURL(url) }
                .buttonStyle(.glassProminent)
                .help("Open the provider’s page")
        }
        Button("Search on Google", systemImage: "magnifyingglass") {
            openURL(AppointmentLogic.googleSearchURL([slot.doctorName, slot.doctorSubtitle, slot.address]))
        }
        .buttonStyle(.glass)
        if detail.booking == nil && family.canEdit {
            Button("Mark as booked", systemImage: "calendar.badge.checkmark") { booking = true }
                .buttonStyle(.glass)
                .keyboardShortcut("b", modifiers: .command)
                .help("Mark as booked (⌘B)")
        }
        if family.canEdit {
            Button("Ignore", systemImage: "eye.slash") {
                perform {
                    try await AppointmentActions.ignore(family, resultID: slot.resultId)
                    dismiss()
                }
            }
            .buttonStyle(.glass)
            .help("Skip this doctor with this reason for the visit in this search from now on")
        }
    }
}

/// "Booked this appointment?" (book-dialog.tsx): the day and time (the slot's, changeable),
/// optional end, for whom (the family's names as chips), a note, and whether to stop the search.
struct AppointmentBookSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let detail: AppointmentSlotDetail
    let saved: () async -> Void

    @State private var day: Date
    @State private var start: Date
    @State private var hasEnd = false
    @State private var end: Date
    @State private var person = ""
    @State private var note = ""
    @State private var stop: Bool
    @State private var saving = false

    init(detail: AppointmentSlotDetail, saved: @escaping () async -> Void) {
        self.detail = detail
        self.saved = saved
        let slotDate = detail.slot.date ?? Date()
        _day = State(initialValue: slotDate)
        _start = State(initialValue: slotDate)
        _end = State(initialValue: slotDate.addingTimeInterval(30 * 60))
        _stop = State(initialValue: detail.searchEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    DatePicker("Time", selection: $start, displayedComponents: .hourAndMinute)
                    Toggle("Until (optional)", isOn: $hasEnd)
                    if hasEnd {
                        DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Book it on the practice’s page first. Ohana then shows it in the calendar (and in the calendar feed, if you subscribed with booked appointments).")
                }
                Section("For whom") {
                    TextField("For whom", text: $person, prompt: Text("e.g. Mia"))
                        .onChange(of: person) { _, value in
                            if value.count > 80 { person = String(value.prefix(80)) }
                        }
                    if !detail.people.isEmpty {
                        AppointmentChips(names: detail.people, selected: $person)
                    }
                }
                Section("Note") {
                    TextField("Note", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .onChange(of: note) { _, value in
                            if value.count > 1000 { note = String(value.prefix(1000)) }
                        }
                }
                if detail.searchEnabled {
                    Section {
                        Toggle("Stop watching this search", isOn: $stop)
                    } footer: {
                        Text("Turns the search off; you can turn it on again when editing it.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Booked this appointment?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to calendar") { save() }
                        .disabled(saving || (hasEnd && AppointmentLogic.timeString(end) < AppointmentLogic.timeString(start)))
                }
            }
        }
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
    }

    /// What the dialog sends.
    var input: AppointmentBookingInput {
        AppointmentBookingInput(
            date: AppointmentLogic.localParts(day).date,
            start: AppointmentLogic.timeString(start),
            end: hasEnd ? AppointmentLogic.timeString(end) : nil,
            person: person.trimmingCharacters(in: .whitespaces),
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            stopSearch: detail.searchEnabled && stop
        )
    }

    private func save() {
        saving = true
        let body = input
        perform {
            defer { saving = false }
            let _: AppointmentBookingResponse = try await family.api.send(
                .post, "/appointments/searches/\(detail.searchId)/slots/\(detail.slot.resultId)/book", body: body
            )
            family.didChange(.appointments, .events, .calendar)
            await saved()
            dismiss()
        }
    }
}

/// The family's names as toggle chips: one tap fills "who is it for", another clears it.
struct AppointmentChips: View {
    let names: [String]
    @Binding var selected: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(names, id: \.self) { name in
                        let on = selected == name
                        Button {
                            selected = on ? "" : name
                        } label: {
                            Text(verbatim: name)
                                .font(.subheadline)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(on ? .regular.tint(ModuleTint.appointments.opacity(0.5)).interactive() : .regular.interactive(), in: .capsule)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
