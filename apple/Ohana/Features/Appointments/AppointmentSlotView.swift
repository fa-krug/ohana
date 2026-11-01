import MapKit
import SwiftUI

/// One slot (slot-detail.tsx): the doctor, time, practice and address on a map, the distance
/// from home; book on the provider's page, mark as booked (a calendar event), ignore. Its
/// commands are in the Appointments menu too while it's on screen.
struct AppointmentSlotView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let searchID: String
    let resultID: Int
    @State private var state: LoadState<AppointmentSlotDetail> = .idle
    @State private var booking = false
    @State private var confirmRemove = false
    /// On screen (not covered by a pushed page): only then it sets the module menu.
    @State private var onScreen = false

    /// Booking, removing and ignoring wait while what's shown is the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

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
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .focusedSceneValue(\.moduleMenu, onScreen ? state.value.map(menu) : nil)
        .sheet(isPresented: $booking) {
            if let detail = state.value {
                AppointmentBookSheet(detail: detail) { await load() }
            }
        }
        .confirmationDialog(Text("Remove the appointment with \(state.value?.slot.doctorName ?? "")?"),
                            isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let eventID = state.value?.booking?.eventId else { return }
                perform { try await AppointmentActions.removeBooking(family, eventID) }
            }
        } message: {
            Text("Remove this appointment from Ohana? This doesn’t cancel it with the practice.")
        }
    }

    private func load() async {
        await LoadState.run($state, family.api.cached("/appointments/searches/\(searchID)/slots/\(resultID)"))
    }

    /// The Appointments menu: the page's actions, Mark as Booked with ⌘B.
    private func menu(_ detail: AppointmentSlotDetail) -> ModuleMenu {
        ModuleMenu(title: "Appointments") {
            if let url = detail.slot.bookingURL {
                Button("Book on \(detail.slot.sourceName)") { openURL(url) }
            }
            if canEdit {
                Button("Mark as Booked…") { booking = true }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(detail.booking != nil)
                Button("Ignore This Doctor") { ignore(detail.slot) }
            }
        }
    }

    private func ignore(_ slot: AppointmentDoctorSlot) {
        perform {
            try await AppointmentActions.ignore(family, resultID: slot.resultId)
            dismiss()
        }
    }

    private func header(_ detail: AppointmentSlotDetail) -> some View {
        let slot = detail.slot
        return VStack(alignment: .leading, spacing: 8) {
            Text(slot.doctorName)
                .font(.title2.weight(.semibold))
            Text(AppointmentLogic.formatSlot(slot.slot, full: true))
                .font(.headline)
                .foregroundStyle(ModuleTint.appointments)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { headerChips(slot) }
                VStack(alignment: .leading, spacing: 6) { headerChips(slot) }
            }
            Text(detail.searchName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentCard()
    }

    @ViewBuilder private func headerChips(_ slot: AppointmentDoctorSlot) -> some View {
        Text(slot.isNextSlot ? "Next available appointment" : "Bookable appointment")
            .font(.caption.weight(.medium))
            .chip()
        Text(verbatim: slot.sourceName)
            .font(.caption.weight(.medium))
            .chip(tint: ModuleTint.appointments)
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
            // Floats over the map: glass is right here.
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
                        Button("Set it") { family.open(.settings(.home)) }
                            .buttonStyle(.borderless)
                    }
                }
            } else {
                fact("Distance from home", unknown)
            }
        }
        .font(.subheadline)
        .contentCard()
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
                Button("Calendar", systemImage: "calendar") {
                    family.open(AppointmentLogic.calendarRoute(date: booked.date))
                }
                .buttonStyle(.bordered)
                if canEdit {
                    Button("Remove", systemImage: "trash", role: .destructive) { confirmRemove = true }
                        .buttonStyle(.bordered)
                }
            }
        }
        .contentCard(tint: .green)
    }

    private func actions(_ detail: AppointmentSlotDetail) -> some View {
        let slot = detail.slot
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { actionButtons(detail, slot) }
            VStack(alignment: .leading, spacing: 12) { actionButtons(detail, slot) }
        }
        .controlSize(.large)
    }

    @ViewBuilder private func actionButtons(_ detail: AppointmentSlotDetail, _ slot: AppointmentDoctorSlot) -> some View {
        if let url = slot.bookingURL {
            Button("Book", systemImage: "arrow.up.right.square") { openURL(url) }
                .buttonStyle(.borderedProminent)
                .help("Open the provider’s page")
        }
        Button("Search on Google", systemImage: "magnifyingglass") {
            openURL(AppointmentLogic.googleSearchURL([slot.doctorName, slot.doctorSubtitle, slot.address]))
        }
        .buttonStyle(.bordered)
        if detail.booking == nil && canEdit {
            Button("Mark as booked", systemImage: "calendar.badge.checkmark") { booking = true }
                .buttonStyle(.bordered)
                .help("Mark as booked (⌘B)")
        }
        if canEdit {
            Button("Ignore", systemImage: "eye.slash") { ignore(slot) }
                .buttonStyle(.bordered)
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
    private let slotDate: Date

    init(detail: AppointmentSlotDetail, saved: @escaping () async -> Void) {
        self.detail = detail
        self.saved = saved
        let slotDate = detail.slot.date ?? Date()
        self.slotDate = slotDate
        _day = State(initialValue: slotDate)
        _start = State(initialValue: slotDate)
        _end = State(initialValue: slotDate.addingTimeInterval(30 * 60))
        _stop = State(initialValue: detail.searchEnabled)
    }

    private var hasChanges: Bool {
        day != slotDate || start != slotDate || hasEnd || !person.isEmpty || !note.isEmpty || stop != detail.searchEnabled
    }

    private var endBeforeStart: Bool {
        hasEnd && AppointmentLogic.timeString(end) < AppointmentLogic.timeString(start)
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
                    if endBeforeStart {
                        Label("The end is before the start.", systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text("Book it on the practice’s page first. Ohana then shows it in the calendar (and in the calendar feed, if you subscribed with booked appointments).")
                    }
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
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to calendar") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || endBeforeStart)
                }
            }
        }
        .discardGuard(hasChanges: hasChanges)
        .errorBanner()
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
            ErrorBanner.shared.success(String(localized: "Added to the calendar."))
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
            HStack(spacing: 8) {
                ForEach(names, id: \.self) { name in
                    let on = selected == name
                    Button {
                        selected = on ? "" : name
                    } label: {
                        // Selected shows as a check and bold, not by color alone.
                        Label {
                            Text(verbatim: name)
                        } icon: {
                            if on { Image(systemName: "checkmark") }
                        }
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? ModuleTint.appointments : .primary)
                        .chip(tint: on ? ModuleTint.appointments : nil)
                        .rowHitTarget()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}
