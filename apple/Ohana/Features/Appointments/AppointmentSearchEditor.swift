import SwiftUI

/// New / edit search (search-form.tsx): name and switches, the place (Photon suggestions or the
/// family's home), the sources with their speciality autocompletes and filters, the schedule,
/// the notification channels. Checked like the server's `searchInputSchema` before saving.
struct AppointmentSearchEditor: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let search: AppointmentSearch?
    /// After saving, with the search's id.
    let saved: (String) -> Void

    @State private var input: AppointmentSearchInput
    @State private var options: AppointmentOptions?
    @State private var locationText: String
    @State private var specialityText: String
    @State private var jamedaText: String
    @State private var problems: [String] = []
    @State private var saving = false

    init(search: AppointmentSearch?, saved: @escaping (String) -> Void) {
        self.search = search
        self.saved = saved
        let input = search.map(AppointmentSearchInput.init) ?? AppointmentSearchInput()
        _input = State(initialValue: input)
        _locationText = State(initialValue: input.locationLabel.isEmpty && !input.latitude.isEmpty
            ? "\(input.latitude), \(input.longitude)" : input.locationLabel)
        _specialityText = State(initialValue: input.specialityLabel.isEmpty ? input.specialitySlug : input.specialityLabel)
        _jamedaText = State(initialValue: input.jamedaSpecialityLabel.isEmpty ? input.jamedaSpecialitySlug : input.jamedaSpecialityLabel)
    }

    var body: some View {
        NavigationStack {
            Form {
                if !problems.isEmpty {
                    Section {
                        ForEach(problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                general
                location
                sources
                schedule
                notifications
            }
            .formStyle(.grouped)
            .navigationTitle(search == nil ? "New search" : "Edit search")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(search == nil ? "Create search" : "Save") { save() }
                        .disabled(saving || input.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task { await loadOptions() }
        }
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
            // A new search notifies the family's only channel, as the web form does.
            if search == nil, input.channelIds.isEmpty, loaded.channels.count == 1 {
                input.channelIds = [loaded.channels[0].id]
            }
        } catch {
            problems = [error.localizedDescription]
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("General") {
            TextField("Name", text: $input.name, prompt: Text("e.g. Dermatologist Munich"))
                .onChange(of: input.name) { _, value in
                    if value.count > 200 { input.name = String(value.prefix(200)) }
                }
            Toggle("Run on the schedule", isOn: $input.enabled)
            Toggle("Only notify when an appointment is earlier than the earliest seen so far", isOn: $input.notifyOnlyEarlier)
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
            if let home = options?.home {
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
            if !input.latitude.isEmpty {
                Text(verbatim: "\(input.latitude), \(input.longitude)")
            }
        }
    }

    @ViewBuilder private var sources: some View {
        Section("Where to search") {
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
        }
    }

    private var schedule: some View {
        Section("Schedule") {
            Picker("Frequency", selection: $input.scheduleType) {
                Text("Every N minutes").tag("MINUTES")
                Text("Hourly").tag("HOURLY")
                Text("Daily").tag("DAILY")
                Text("Cron expression").tag("CRON")
            }
            if input.scheduleType == "MINUTES" {
                AppointmentNumberField(
                    label: "Interval (minutes)",
                    value: Binding(get: { input.scheduleMinutes ?? 30 }, set: { input.scheduleMinutes = $0 }),
                    range: 1...1440
                )
            }
            if input.scheduleType == "CRON" {
                LabeledContent("Cron (m h dom mon dow)") {
                    TextField("Cron (m h dom mon dow)", text: $input.cron, prompt: Text(verbatim: "*/15 * * * *"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            }
            AppointmentNumberField(label: "Within (days)", value: $input.dayLimit, range: 1...365)
            AppointmentNumberField(label: "Result pages", value: $input.maxPages, range: 1...20)
        }
    }

    @ViewBuilder private var notifications: some View {
        Section {
            if let options {
                if options.channels.isEmpty {
                    Text("Your family has no notification channels yet.")
                        .foregroundStyle(.secondary)
                    Button("Add one in the settings.") {
                        dismiss()
                        family.open(.settings(.notifications))
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

    // MARK: Saving

    private func save() {
        problems = AppointmentLogic.problems(input)
        guard problems.isEmpty else { return }
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
                problems = [error.localizedDescription]
            }
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
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
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

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                TextField(label, value: $value, format: .number)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Stepper(label, value: $value, in: range)
                    .labelsHidden()
            }
        }
    }
}
