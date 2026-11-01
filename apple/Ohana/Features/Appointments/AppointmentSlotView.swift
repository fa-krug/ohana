import MapKit
import SwiftUI

/// One slot (slot-detail.tsx): the doctor, time, practice and address on a map, the distance
/// from home; book on the provider's page, mark as booked (a calendar event), ignore. Its
/// commands are in the Appointments menu too while it's on screen. Back from the provider's page
/// (an in-app Safari view on iOS; the browser on the Mac, back when the app is active again), an
/// editor gets the booking sheet as "Did you book it?", filled in and stopping the search.
struct AppointmentSlotView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let searchID: String
    let resultID: Int
    @State private var state: LoadState<AppointmentSlotDetail> = .idle
    @State private var booking = false
    /// The booking sheet opened on the way back from the provider's page.
    @State private var askBooked = false
    #if os(iOS)
    @State private var provider: ProviderPage?
    #else
    /// The provider's page is open in the browser: ask when the app is active again.
    @State private var awaitingReturn = false
    #endif
    @State private var confirmRemove = false
    /// On screen (not covered by a pushed page): only then it sets the module menu.
    @State private var onScreen = false

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
        .sheet(isPresented: $booking, onDismiss: { askBooked = false }) {
            if let detail = state.value {
                AppointmentBookSheet(detail: detail, afterVisit: askBooked) { await load() }
            }
        }
        #if os(iOS)
        .fullScreenCover(item: $provider, onDismiss: returnedFromProvider) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard awaitingReturn else { return }
            awaitingReturn = false
            returnedFromProvider()
        }
        #endif
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

    /// Opens the provider's booking page (in the app on iOS).
    private func openProvider(_ url: URL) {
        #if os(iOS)
        provider = ProviderPage(url: url)
        #else
        awaitingReturn = true
        openURL(url)
        #endif
    }

    /// Back from the provider's page: did they book it? Only for editors, and only while the
    /// slot isn't marked as booked.
    private func returnedFromProvider() {
        guard family.canEdit, state.value?.booking == nil else { return }
        askBooked = true
        booking = true
    }

    private func load() async {
        await LoadState.run($state) { try await family.api.get("/appointments/searches/\(searchID)/slots/\(resultID)") }
    }

    /// The Appointments menu: the page's actions, Mark as Booked with ⌘B.
    private func menu(_ detail: AppointmentSlotDetail) -> ModuleMenu {
        ModuleMenu(title: "Appointments") {
            if let url = detail.slot.bookingURL {
                Button("Book on \(detail.slot.sourceName)") { openProvider(url) }
            }
            if family.canEdit {
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
                if family.canEdit {
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
            Button("Book", systemImage: "arrow.up.right.square") { openProvider(url) }
                .buttonStyle(.borderedProminent)
                .help("Open the provider’s page")
        }
        Button("Search on Google", systemImage: "magnifyingglass") {
            openURL(AppointmentLogic.googleSearchURL([slot.doctorName, slot.doctorSubtitle, slot.address]))
        }
        .buttonStyle(.bordered)
        if detail.booking == nil && family.canEdit {
            Button("Mark as booked", systemImage: "calendar.badge.checkmark") { booking = true }
                .buttonStyle(.bordered)
                .help("Mark as booked (⌘B)")
        }
        if family.canEdit {
            Button("Ignore", systemImage: "eye.slash") { ignore(slot) }
                .buttonStyle(.bordered)
                .help("Skip this doctor with this reason for the visit in this search from now on")
        }
    }
}

#if os(iOS)
/// The provider's page in the Safari view.
private struct ProviderPage: Identifiable {
    let url: URL
    var id: URL { url }
}
#endif

/// "Booked this appointment?" (book-dialog.tsx): the day and time (the slot's, changeable),
/// optional end, for whom (the family's names as chips, the likely one chosen), a note, and
/// whether to stop the search (ticked). After a visit to the provider's page it asks "Did you
/// book it?", and its Cancel is "Not Yet".
struct AppointmentBookSheet: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let detail: AppointmentSlotDetail
    var afterVisit = false
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
    private let suggestedPerson: String

    init(detail: AppointmentSlotDetail, afterVisit: Bool = false, saved: @escaping () async -> Void) {
        self.detail = detail
        self.afterVisit = afterVisit
        self.saved = saved
        suggestedPerson = detail.suggestedPerson ?? ""
        _person = State(initialValue: suggestedPerson)
        let slotDate = detail.slot.date ?? Date()
        self.slotDate = slotDate
        _day = State(initialValue: slotDate)
        _start = State(initialValue: slotDate)
        _end = State(initialValue: slotDate.addingTimeInterval(30 * 60))
        _stop = State(initialValue: detail.searchEnabled)
    }

    private var hasChanges: Bool {
        day != slotDate || start != slotDate || hasEnd || person != suggestedPerson || !note.isEmpty
            || stop != detail.searchEnabled
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
                    } else if afterVisit {
                        Text("Check the day and time the practice confirmed. Ohana then shows it in the calendar (and in the calendar feed, if you subscribed with booked appointments).")
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
            .navigationTitle(afterVisit ? Text("Did you book it?") : Text("Booked this appointment?"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(title: afterVisit ? "Not Yet" : "Cancel", hasChanges: hasChanges)
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
