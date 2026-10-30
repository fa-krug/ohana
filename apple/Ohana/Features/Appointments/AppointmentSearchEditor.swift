import SwiftUI

/// New / edit search (search-form.tsx): name, the place (the family's home by default, Photon
/// suggestions otherwise), the sources with their speciality autocompletes and filters, how often
/// it runs in plain words (cron and result pages under "Advanced"), the notification channels.
/// Checked like the server's `searchInputSchema`: each problem shows at its field (muted until
/// the field was touched) and Save waits until there are none.
struct AppointmentSearchEditor: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let search: AppointmentSearch?
    /// After saving, with the search's id.
    let saved: (String) -> Void

    @State private var input: AppointmentSearchInput
    /// What Cancel compares with: the search, or a new one with its defaults (home, channel).
    @State private var original: AppointmentSearchInput
    @State private var options: AppointmentOptions?
    @State private var locationText: String
    @State private var specialityText: String
    @State private var jamedaText: String
    private let originalTexts: [String]
    @State private var schedule: AppointmentSchedule
    /// The plain choice to go back to when cron is switched off again.
    @State private var lastPlainSchedule: AppointmentSchedule
    @State private var showAdvanced: Bool
    /// Fields edited since the sheet opened: their problems show in red, the others muted.
    @State private var touched: Set<AppointmentSearchField> = []
    @State private var saving = false
    @State private var confirmLeave = false

    init(search: AppointmentSearch?, saved: @escaping (String) -> Void) {
        self.search = search
        self.saved = saved
        let input = search.map(AppointmentSearchInput.init) ?? AppointmentSearchInput()
        _input = State(initialValue: input)
        _original = State(initialValue: input)
        // A place without a name is never shown as raw coordinates.
        let location = input.locationLabel.isEmpty && !input.latitude.isEmpty
            ? String(localized: "Selected place") : input.locationLabel
        let speciality = input.specialityLabel.isEmpty ? input.specialitySlug : input.specialityLabel
        let jameda = input.jamedaSpecialityLabel.isEmpty ? input.jamedaSpecialitySlug : input.jamedaSpecialityLabel
        _locationText = State(initialValue: location)
        _specialityText = State(initialValue: speciality)
        _jamedaText = State(initialValue: jameda)
        originalTexts = [location, speciality, jameda]
        let schedule = AppointmentLogic.schedule(of: input)
        _schedule = State(initialValue: schedule)
        _lastPlainSchedule = State(initialValue: schedule == .cron ? .every30Minutes : schedule)
        _showAdvanced = State(initialValue: schedule == .cron || input.maxPages != AppointmentSearchInput().maxPages)
    }

    private var issues: [(field: AppointmentSearchField, message: String)] { AppointmentLogic.issues(input) }

    private var hasChanges: Bool {
        input != original || [locationText, specialityText, jamedaText] != originalTexts
    }

    var body: some View {
        NavigationStack {
            Form {
                general
                location
                sources
                scheduleSection
                notifications
                advanced
            }
            .formStyle(.grouped)
            .navigationTitle(search == nil ? "New search" : "Edit search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: hasChanges)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(search == nil ? "Create search" : "Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!issues.isEmpty)
                    }
                }
            }
            .task { await loadOptions() }
            .onChange(of: input.name) { touched.insert(.name) }
            .onChange(of: locationText) { touched.insert(.location) }
            .onChange(of: specialityText) { touched.insert(.doctolibSpeciality) }
            .onChange(of: jamedaText) { touched.insert(.jamedaSpeciality) }
            .onChange(of: input.dayLimit) { touched.insert(.dayLimit) }
            .onChange(of: input.maxPages) { touched.insert(.maxPages) }
            .onChange(of: input.scheduleMinutes) { touched.insert(.interval) }
            .onChange(of: input.cron) { touched.insert(.cron) }
            .confirmationDialog("Discard your changes?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive, action: openChannelSettings)
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .discardGuard(hasChanges: hasChanges)
        .errorBanner()
        .presentationDetents([.large])
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #endif
    }

    private func loadOptions() async {
        guard options == nil else { return }
        do {
            let loaded: AppointmentOptions = try await family.api.get("/appointments/options")
            options = loaded
            guard search == nil else { return }
            // A new search starts at home and notifies the family's only channel (as the web form
            // does): defaults, not changes, so Cancel doesn't ask about them.
            if let home = loaded.home {
                original.latitude = String(home.lat)
                original.longitude = String(home.lng)
                original.locationLabel = home.address
                if input.latitude.isEmpty, locationText.isEmpty {
                    input.latitude = original.latitude
                    input.longitude = original.longitude
                    input.locationLabel = home.address
                    locationText = home.address
                }
            }
            if loaded.channels.count == 1 {
                original.channelIds = [loaded.channels[0].id]
                if input.channelIds.isEmpty { input.channelIds = original.channelIds }
            }
        } catch {
            ErrorBanner.shared.show(error)
        }
    }

    // MARK: Inline problems

    /// The field's problem: red once the field was touched (or the search exists), muted before.
    @ViewBuilder private func problem(_ field: AppointmentSearchField) -> some View {
        if let message = issues.first(where: { $0.field == field })?.message {
            if search != nil || touched.contains(field) {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            } else {
                Text(message)
            }
        }
    }

    private func hasProblem(_ field: AppointmentSearchField) -> Bool {
        issues.contains { $0.field == field }
    }

    // MARK: Sections

    private var general: some View {
        Section {
            TextField("Name", text: $input.name, prompt: Text("e.g. Dermatologist Munich"))
                .onChange(of: input.name) { _, value in
                    if value.count > 200 { input.name = String(value.prefix(200)) }
                }
            Toggle("Only notify when an appointment is earlier than the earliest seen so far", isOn: $input.notifyOnlyEarlier)
        } header: {
            Text("General")
        } footer: {
            problem(.name)
        }
    }

    private var location: some View {
        Section {
            AppointmentAutocomplete(
                prompt: "Search a city or address…",
                text: $locationText,
                fetch: { q in try await family.api.get("/geocode", query: ["q": q]) as [AppointmentLocationSuggestion] },
                title: \.label
            ) { place in
                input.latitude = place.latitude
                input.longitude = place.longitude
                input.locationLabel = place.label
            }
            if let home = options?.home, input.locationLabel != home.address {
                Button("Use the home address", systemImage: "house") {
                    input.latitude = String(home.lat)
                    input.longitude = String(home.lng)
                    input.locationLabel = home.address
                    locationText = home.address
                }
            }
        } header: {
            Text("Location")
        } footer: {
            if hasProblem(.location) {
                problem(.location)
            } else if let home = options?.home, input.locationLabel == home.address {
                Text("Searches around your home address.")
            } else {
                Text("Searches around this place.")
            }
        }
    }

    @ViewBuilder private var sources: some View {
        Section {
            Toggle(isOn: $input.doctolibOn) { Text(verbatim: "Doctolib").fontWeight(.semibold) }
            if input.doctolibOn {
                AppointmentAutocomplete(
                    label: "Speciality",
                    prompt: "Search a speciality…",
                    text: $specialityText,
                    fetch: { q in try await family.api.get("/appointments/doctolib-specialities", query: ["q": q]) as [AppointmentSpecialitySuggestion] },
                    title: \.label
                ) { item in
                    input.specialitySlug = item.slug
                    input.specialityLabel = item.label
                }
                Picker("Insurance", selection: $input.insuranceSector) {
                    Text("Any").tag("")
                    Text("Public").tag("public")
                    Text("Private").tag("private")
                }
                if let url = AppointmentLogic.doctolibPreviewURL(input) {
                    Button("Preview on Doctolib", systemImage: "arrow.up.right.square") { openURL(url) }
                }
            }
        } header: {
            Text("Where to search")
        } footer: {
            problem(.doctolibSpeciality)
        }
        Section {
            Toggle(isOn: $input.jamedaOn) { Text(verbatim: "jameda").fontWeight(.semibold) }
            if input.jamedaOn {
                AppointmentAutocomplete(
                    label: "Speciality, treatment or condition",
                    prompt: "Search a speciality…",
                    text: $jamedaText,
                    fetch: { q in try await family.api.get("/appointments/jameda-terms", query: ["q": q]) as [AppointmentJamedaTerm] },
                    title: \.label,
                    meta: { AppointmentLogic.termTypeLabel($0.type) }
                ) { term in
                    input.jamedaSpecialitySlug = term.slug
                    input.jamedaSpecialityLabel = term.label
                    input.jamedaSpecialityType = term.type
                }
                if !input.jamedaSpecialitySlug.isEmpty {
                    LabeledContent("Kind", value: AppointmentLogic.termTypeLabel(input.jamedaSpecialityType))
                }
                Picker("Insurance", selection: $input.jamedaInsuranceType) {
                    Text("Any").tag("")
                    Text("Public").tag("government")
                    Text("Private").tag("private")
                    Text("Self-payer").tag("public_selfpay")
                }
                Toggle("Child-friendly only", isOn: $input.jamedaKidsFriendly)
                Picker("Video consultations", selection: $input.jamedaVideo) {
                    Text("Any").tag("any")
                    Text("Video consultations only").tag("only")
                    Text("Hide video consultations").tag("exclude")
                }
                if let url = AppointmentLogic.jamedaPreviewURL(input) {
                    Button("Preview on jameda", systemImage: "arrow.up.right.square") { openURL(url) }
                }
            }
        } footer: {
            problem(.jamedaSpeciality)
        }
    }

    private var scheduleSection: some View {
        Section {
            Toggle("Check automatically", isOn: $input.enabled)
            if input.enabled {
                Picker("How often", selection: Binding(get: { schedule }, set: choose)) {
                    ForEach(AppointmentSchedule.presets) { choice in
                        Text(choice.title).tag(choice)
                    }
                    if schedule == .cron {
                        Text(AppointmentSchedule.cron.title).tag(AppointmentSchedule.cron)
                    }
                }
                if schedule == .customInterval {
                    AppointmentNumberField(
                        label: "Every (minutes)",
                        value: Binding(get: { input.scheduleMinutes ?? 60 }, set: { input.scheduleMinutes = $0 }),
                        range: 1...1440
                    )
                }
            }
            AppointmentNumberField(label: "Within (days)", value: $input.dayLimit, range: 1...365)
        } header: {
            Text("Schedule")
        } footer: {
            if hasProblem(.interval) || hasProblem(.dayLimit) {
                VStack(alignment: .leading, spacing: 4) {
                    problem(.interval)
                    problem(.dayLimit)
                }
            } else if input.enabled {
                Text("Ohana checks on its own and tells you when an appointment frees up. Within (days): how far ahead an appointment may be.")
            } else {
                Text("Ohana checks only when you tap Run now. Within (days): how far ahead an appointment may be.")
            }
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            if let options {
                if options.channels.isEmpty {
                    Text("Your family has no notification channels yet.")
                        .foregroundStyle(.secondary)
                    Button("Add one in the settings.") {
                        if hasChanges { confirmLeave = true } else { openChannelSettings() }
                    }
                } else {
                    ForEach(options.channels) { channel in
                        Toggle(isOn: Binding(
                            get: { input.channelIds.contains(channel.id) },
                            set: { on in
                                if on { if !input.channelIds.contains(channel.id) { input.channelIds.append(channel.id) } }
                                else { input.channelIds.removeAll { $0 == channel.id } }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(verbatim: channel.name)
                                Group {
                                    if channel.enabled {
                                        Text(verbatim: channel.provider)
                                    } else {
                                        Text("\(channel.provider) (disabled)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        } header: {
            Text("Notifications")
        } footer: {
            if let options, !options.channels.isEmpty {
                Text("Where new appointments of this search are sent.")
            }
        }
    }

    /// Cron and result pages: for those who know them, folded away.
    private var advanced: some View {
        Section {
            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                Toggle("Use a cron schedule", isOn: Binding(get: { schedule == .cron }, set: { on in
                    choose(on ? .cron : lastPlainSchedule)
                    if on { input.enabled = true }
                }))
                if schedule == .cron {
                    TextField("Cron expression", text: $input.cron, prompt: Text(verbatim: "*/15 7-20 * * 1-5"))
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    VStack(alignment: .leading, spacing: 4) {
                        problem(.cron)
                        Text("Five fields: minute, hour, day of the month, month, weekday. “*/15 7-20 * * 1-5” runs every 15 minutes from 7:00 to 20:59 on weekdays.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
                AppointmentNumberField(label: "Result pages", value: $input.maxPages, range: 1...20)
                VStack(alignment: .leading, spacing: 4) {
                    problem(.maxPages)
                    Text("How many pages of results each run reads per source. More pages find more doctors but take longer.")
                        .foregroundStyle(.secondary)
                }
                .font(.footnote)
            }
        }
    }

    // MARK: Changes

    private func choose(_ choice: AppointmentSchedule) {
        schedule = choice
        if choice != .cron { lastPlainSchedule = choice }
        AppointmentLogic.apply(choice, to: &input)
    }

    private func openChannelSettings() {
        dismiss()
        family.open(.settings(.notifications))
    }

    private func save() {
        guard issues.isEmpty, !saving else { return }
        saving = true
        let body = input
        Task {
            defer { saving = false }
            do {
                let id: String
                if let search {
                    try await family.api.perform(.patch, "/appointments/searches/\(search.id)", body: body)
                    id = search.id
                } else {
                    let created: AppointmentCreatedResponse = try await family.api.send(.post, "/appointments/searches", body: body)
                    id = created.id
                }
                family.didChange(.appointments)
                ErrorBanner.shared.success(search == nil ? String(localized: "Search created.") : String(localized: "Search saved."))
                dismiss()
                saved(id)
            } catch is CancellationError {
            } catch {
                ErrorBanner.shared.show(error)
            }
        }
    }
}


extension AppointmentSchedule {
    var title: LocalizedStringKey {
        switch self {
        case .every5Minutes: "Every 5 minutes"
        case .every15Minutes: "Every 15 minutes"
        case .every30Minutes: "Every 30 minutes"
        case .hourly: "Every hour"
        case .daily: "Once a day"
        case .customInterval: "Another interval"
        case .cron: "Custom schedule (Advanced)"
        }
    }
}

/// A text field that asks a server route for suggestions as you type (the web's AsyncCombobox);
/// picking one fills the field and calls `select`. The field's text is only what's shown: the
/// value is what was picked last.
struct AppointmentAutocomplete<Item: Identifiable & Hashable>: View {
    var label: LocalizedStringKey?
    let prompt: LocalizedStringKey
    @Binding var text: String
    let fetch: (String) async throws -> [Item]
    let title: (Item) -> String
    var meta: ((Item) -> String)?
    let select: (Item) -> Void

    @State private var suggestions: [Item] = []
    @State private var chosen: String?
    @State private var loading = false
    @FocusState private var focused: Bool

    init(label: LocalizedStringKey? = nil, prompt: LocalizedStringKey, text: Binding<String>,
         fetch: @escaping (String) async throws -> [Item], title: @escaping (Item) -> String,
         meta: ((Item) -> String)? = nil, select: @escaping (Item) -> Void) {
        self.label = label
        self.prompt = prompt
        _text = text
        self.fetch = fetch
        self.title = title
        self.meta = meta
        self.select = select
        _chosen = State(initialValue: text.wrappedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(prompt, text: $text, prompt: Text(prompt))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .focused($focused)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                if loading { ProgressView().controlSize(.small) }
            }
        }
        .task(id: text) { await search() }
        ForEach(suggestions) { item in
            Button {
                let picked = title(item)
                chosen = picked
                text = picked
                suggestions = []
                focused = false
                select(item)
            } label: {
                HStack {
                    Text(verbatim: title(item)).foregroundStyle(.primary)
                    Spacer()
                    if let meta {
                        Text(verbatim: meta(item)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }

    private func search() async {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2, text != chosen else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        let found = (try? await fetch(q)) ?? []
        guard !Task.isCancelled else { return }
        suggestions = Array(found.prefix(8))
    }
}

/// A whole number in a range: a field to type and a stepper.
struct AppointmentNumberField: View {
    let label: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Wide enough for four digits at any text size.
    @ScaledMetric private var fieldWidth: CGFloat = 64

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, value: $value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: fieldWidth)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Stepper(label, value: $value, in: range)
                    .labelsHidden()
            }
        }
    }
}
