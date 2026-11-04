import SwiftUI

/// GET / PUT /holidays: whether the server imports the family's public holidays and school
/// holidays into the calendar (as days of each year's types `holiday` and `school-holidays`), and
/// for which region: the home address's (`auto`) or one picked.
struct CalendarHolidaySettings: Decodable, Equatable {
    enum Status: String, Equatable {
        case ok, pending, noAddress = "no_address", unsupported, failed, off
    }

    var publicHolidays: Bool
    var schoolHolidays: Bool
    /// The region follows the home address.
    var auto: Bool
    /// The region the days are imported for; nil while there is none (no home address).
    var region: CalendarHolidayRegion?
    /// An unknown status (from a newer server) counts as pending: nothing to tell.
    var status: Status
    var syncedAt: String?

    private enum CodingKeys: String, CodingKey {
        case publicHolidays = "public", schoolHolidays = "school", auto, region, status, syncedAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        publicHolidays = try c.decodeIfPresent(Bool.self, forKey: .publicHolidays) ?? false
        schoolHolidays = try c.decodeIfPresent(Bool.self, forKey: .schoolHolidays) ?? false
        auto = try c.decodeIfPresent(Bool.self, forKey: .auto) ?? true
        region = try? c.decodeIfPresent(CalendarHolidayRegion.self, forKey: .region)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .pending
        syncedAt = try? c.decodeIfPresent(String.self, forKey: .syncedAt)
    }

    var isOn: Bool { publicHolidays || schoolHolidays }

    /// What keeps the days from being imported, said in a line; nil when nothing does (or it's off).
    var problem: String? {
        guard isOn else { return nil }
        switch status {
        case .noAddress: return String(localized: "No home address yet: set one under Household → Home address, or pick a region.")
        case .unsupported: return String(localized: "Ohana knows no holidays for this region.")
        case .failed: return String(localized: "The holidays couldn’t be loaded.")
        case .ok, .pending, .off: return nil
        }
    }
}

/// A region of GET /holidays/regions: a country, or (`?country=`) one of its states, which may
/// have smaller regions with holidays of their own (a city).
struct CalendarHolidayRegion: Decodable, Hashable, Identifiable {
    let code: String
    let name: String
    var children: [CalendarHolidayRegion]?

    var id: String { code }

    /// `code` is this region or lies in it ("DE-BY-AU" in "DE-BY" and "DE").
    func contains(_ code: String?) -> Bool {
        guard let code else { return false }
        return code == self.code || code.hasPrefix(self.code + "-")
    }

    static func sorted(_ regions: [CalendarHolidayRegion]) -> [CalendarHolidayRegion] {
        regions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// PUT /holidays: only what changes. `region` .some(nil) follows the home address again.
struct CalendarHolidayUpdate: Encodable {
    var publicHolidays: Bool?
    var schoolHolidays: Bool?
    var region: String??

    private enum CodingKeys: String, CodingKey {
        case publicHolidays = "public", schoolHolidays = "school", region
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(publicHolidays, forKey: .publicHolidays)
        try c.encodeIfPresent(schoolHolidays, forKey: .schoolHolidays)
        if let region { try c.encode(region, forKey: .region) }
    }
}

/// The holidays section's settings as loaded, saving them, and its region picker.
@Observable
final class CalendarHolidaysModel {
    private(set) var state: LoadState<CalendarHolidaySettings> = .idle
    /// The region picker is open.
    var picking = false
    @ObservationIgnored private var following: Task<Void, Never>?

    var settings: CalendarHolidaySettings? { state.value }

    func load(_ api: FamilyAPI) async {
        await LoadState.run(Binding(get: { self.state }, set: { self.state = $0 }), api.cached("/holidays"))
    }

    /// Saves a change, a toggle showing at once; a refusal goes to the banner and the settings
    /// load again.
    func save(_ change: CalendarHolidayUpdate, family: FamilyContext) {
        if var shown = settings {
            shown.publicHolidays = change.publicHolidays ?? shown.publicHolidays
            shown.schoolHolidays = change.schoolHolidays ?? shown.schoolHolidays
            state = .loaded(shown)
        }
        let api = family.api
        perform {
            do {
                let answer: CalendarHolidaySettings = try await api.send(.put, "/holidays", body: change)
                self.state = .loaded(answer)
            } catch {
                await self.load(api)
                throw error
            }
            family.didChange(.calendar)
            self.followImport(family)
        }
    }

    /// The server's worker imports the days within seconds of a change: the settings (their
    /// status) and the calendar load again until it's done, for about half a minute at most.
    private func followImport(_ family: FamilyContext) {
        following?.cancel()
        following = Task {
            for delay in [3, 5, 8, 15] {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                await load(family.api)
                family.didChange(.calendar)
                if settings?.status != .pending { return }
            }
        }
    }
}

/// Settings → Calendar: the public holidays and school holidays the server imports for the
/// family's region (the home address's, or one picked) into the types “Holiday” and “School
/// holidays”. Editors change them; viewers see them. Not in the demo, nor when the server has them
/// off. The form loads `model` and presents its picker (`calendarHolidays`).
struct CalendarHolidaysSection: View {
    let model: CalendarHolidaysModel
    @Environment(FamilyContext.self) private var family

    static func isShown(_ family: FamilyContext) -> Bool {
        !family.api.client.isDemo && family.serverInfo?.holidays == true
    }

    var body: some View {
        if Self.isShown(family) {
            Section {
                switch model.state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await model.load(family.api) } }
                case .loaded, .saved:
                    if let settings = model.settings { rows(settings) }
                }
            } header: {
                Text("Holidays")
            } footer: {
                Text("The days go into the types “Holiday” and “School holidays”.")
            }
        }
    }

    @ViewBuilder
    private func rows(_ settings: CalendarHolidaySettings) -> some View {
        // Changes wait while the copy on the device shows.
        let canEdit = family.canEdit && !model.state.isSaved
        Toggle("Public holidays", isOn: Binding(get: { settings.publicHolidays }, set: { on in
            model.save(CalendarHolidayUpdate(publicHolidays: on), family: family)
        }))
        .disabled(!canEdit)
        Toggle("School holidays", isOn: Binding(get: { settings.schoolHolidays }, set: { on in
            model.save(CalendarHolidayUpdate(schoolHolidays: on), family: family)
        }))
        .disabled(!canEdit)
        if settings.isOn {
            if canEdit {
                Button {
                    model.picking = true
                } label: {
                    HStack {
                        region(settings)
                        #if os(iOS)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        #endif
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                region(settings)
            }
            if let problem = settings.problem {
                Label(problem, systemImage: settings.status == .noAddress ? "house" : "exclamationmark.triangle")
                    .foregroundStyle(settings.status == .noAddress ? Color.secondary : Color.orange)
            }
        }
    }

    private func region(_ settings: CalendarHolidaySettings) -> some View {
        LabeledContent("Region") {
            VStack(alignment: .trailing, spacing: 2) {
                if let region = settings.region {
                    Text(verbatim: region.name)
                    if settings.auto {
                        Text("From home address").font(.caption)
                    }
                } else {
                    Text(settings.auto ? LocalizedStringKey("From home address") : LocalizedStringKey("None"))
                }
            }
            .multilineTextAlignment(.trailing)
        }
    }
}

extension View {
    /// Loads the holidays section's settings and presents its region picker; on the form around it.
    func calendarHolidays(_ model: CalendarHolidaysModel) -> some View {
        modifier(CalendarHolidaysModifier(model: model))
    }
}

private struct CalendarHolidaysModifier: ViewModifier {
    @Bindable var model: CalendarHolidaysModel
    @Environment(FamilyContext.self) private var family

    func body(content: Content) -> some View {
        let shown = CalendarHolidaysSection.isShown(family)
        content
            // A new home address may mean another region.
            .task(id: shown ? family.revision(.family) : nil) {
                if shown { await model.load(family.api) }
            }
            .sheet(isPresented: $model.picking) {
                CalendarHolidayRegionPicker(model: model)
            }
    }
}

/// Picks the holidays' region: the home address's, a country, one of its states or a smaller
/// region in one. Picking saves and closes.
private struct CalendarHolidayRegionPicker: View {
    let model: CalendarHolidaysModel
    @Environment(FamilyContext.self) private var family
    @State private var countries: LoadState<[CalendarHolidayRegion]> = .idle
    @State private var query = ""

    /// The region picked before; nil while it follows the home address.
    private var current: String? {
        model.settings.flatMap { $0.auto ? nil : $0.region?.code }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CalendarHolidayRegionChoice(title: String(localized: "From home address"),
                                                checked: model.settings?.auto == true) { pick(nil) }
                }
                Section {
                    CalendarHolidayRegionRows(state: countries, retry: load) { regions in
                        ForEach(CalendarHolidayRegion.sorted(regions.filter(matches))) { country in
                            NavigationLink(value: country) {
                                CalendarHolidayRegionLabel(title: country.name, checked: country.contains(current))
                            }
                        }
                    }
                } header: {
                    Text("Country")
                }
            }
            .formStyle(.grouped)
            .searchable(text: $query)
            .navigationTitle("Region")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: CalendarHolidayRegion.self) { region in
                CalendarHolidayRegionPage(region: region, current: current, pick: pick)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CancelButton(hasChanges: false)
                }
            }
            .task { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private func matches(_ region: CalendarHolidayRegion) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || region.name.localizedStandardContains(text) || region.code.localizedStandardContains(text)
    }

    private func load() async {
        await LoadState.run($countries, family.api.cached("/holidays/regions"))
    }

    private func pick(_ code: String?) {
        model.save(CalendarHolidayUpdate(region: .some(code)), family: family)
        model.picking = false
    }
}

/// A country's states (loaded), or a state's smaller regions: the region itself first.
private struct CalendarHolidayRegionPage: View {
    let region: CalendarHolidayRegion
    let current: String?
    let pick: (String?) -> Void
    @Environment(FamilyContext.self) private var family
    @State private var regions: LoadState<[CalendarHolidayRegion]> = .idle

    var body: some View {
        Form {
            Section {
                CalendarHolidayRegionChoice(title: String(localized: "All of \(region.name)"),
                                            checked: current == region.code) { pick(region.code) }
            }
            Section {
                CalendarHolidayRegionRows(state: regions, retry: load) { regions in
                    ForEach(CalendarHolidayRegion.sorted(regions)) { item($0) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(region.name)
        .task { await load() }
    }

    @ViewBuilder
    private func item(_ sub: CalendarHolidayRegion) -> some View {
        if sub.children?.isEmpty == false {
            NavigationLink(value: sub) {
                CalendarHolidayRegionLabel(title: sub.name, checked: sub.contains(current))
            }
        } else {
            CalendarHolidayRegionChoice(title: sub.name, checked: current == sub.code) { pick(sub.code) }
        }
    }

    private func load() async {
        if let children = region.children {
            regions = .loaded(children)
        } else {
            await LoadState.run($regions, family.api.cached("/holidays/regions", query: ["country": region.code]))
        }
    }
}

/// A list's regions as they load: a spinner, the failure with Try again (the holiday service may
/// be out of reach), or the rows.
private struct CalendarHolidayRegionRows<Content: View>: View {
    let state: LoadState<[CalendarHolidayRegion]>
    let retry: () async -> Void
    @ViewBuilder var content: ([CalendarHolidayRegion]) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await retry() } }
        case let .loaded(regions), let .saved(regions, _, _):
            content(regions)
        }
    }
}

/// A region to pick, with a check on the chosen one.
private struct CalendarHolidayRegionChoice: View {
    let title: String
    let checked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CalendarHolidayRegionLabel(title: title, checked: checked).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A region's name, with a check when the chosen region is (in) it.
private struct CalendarHolidayRegionLabel: View {
    let title: String
    let checked: Bool

    var body: some View {
        HStack {
            Text(verbatim: title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if checked {
                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.accentColor)
            }
        }
    }
}
