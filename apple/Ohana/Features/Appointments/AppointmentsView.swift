import SwiftUI

/// Appointments (the web app's app/(app)/f/[familyId]/appointments): the booked appointments and
/// the family's searches as glass cards with their status and earliest slots; editors add,
/// run, pause and delete searches. Inside the shell's navigation stack.
struct AppointmentsView: View {
    @Environment(FamilyContext.self) private var family
    @State private var state: LoadState<AppointmentsOverview> = .idle
    @State private var query = ""
    @State private var creating = false
    @State private var editing: AppointmentSearch?
    @State private var deleting: AppointmentSearch?
    @State private var removing: AppointmentEvent?
    /// Pushed from code: a search just created, a context menu's "Open".
    @State private var pushed: AppointmentRoute?

    var body: some View {
        LoadStateView(state: state, retry: load) { overview in
            content(overview)
        }
        .ohanaBackground(ModuleTint.appointments)
        .navigationTitle("Appointments")
        .searchable(text: $query, prompt: Text("Search searches"))
        .toolbar {
            if family.canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("New search", systemImage: "plus") { creating = true }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        .help("New search (⇧⌘N)")
                }
            }
        }
        .task(id: [family.revision(.appointments), family.revision(.events)]) { await load() }
        .appointmentPolling(busy: state.value?.searches.contains(where: \.isBusy) ?? false) { await load() }
        .navigationDestination(for: AppointmentRoute.self) { AppointmentRouteView(route: $0) }
        // `.id`: another route replaces the pushed page with a fresh one.
        .navigationDestination(item: $pushed) { AppointmentRouteView(route: $0).id($0) }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .appointments) else { return }
            switch AppointmentRoute.from(route) {
            case let .push(target): pushed = target
            case .newSearch: if family.canEdit { creating = true }
            case .list: pushed = nil
            }
        }
        .sheet(isPresented: $creating) {
            AppointmentSearchEditor(search: nil) { id in pushed = .search(id) }
        }
        .sheet(item: $editing) { search in
            AppointmentSearchEditor(search: search) { _ in }
        }
        .confirmationDialog(
            "Delete the search?", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { search in
            Button("Delete", role: .destructive) {
                perform {
                    try await AppointmentActions.delete(family, search.id)
                }
            }
        } message: { search in
            Text("Delete the search “\(search.name)” with its history?")
        }
        .confirmationDialog(
            "Remove the appointment?", isPresented: .init(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { event in
            Button("Remove", role: .destructive) {
                perform { try await AppointmentActions.removeBooking(family, event.id) }
            }
        } message: { _ in
            Text("Remove this appointment from Ohana? This doesn’t cancel it with the practice.")
        }
    }

    private func load() async {
        await LoadState.run($state) { try await family.api.get("/appointments") }
    }

    private func filtered(_ searches: [AppointmentSearch]) -> [AppointmentSearch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return searches }
        return searches.filter {
            $0.name.localizedCaseInsensitiveContains(q) || AppointmentLogic.criteriaSummary($0).localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder private func content(_ overview: AppointmentsOverview) -> some View {
        let searches = filtered(overview.searches)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Watches Doctolib and jameda and tells you when an appointment frees up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                if !overview.booked.isEmpty {
                    bookedSection(overview.booked)
                }

                if overview.searches.isEmpty {
                    emptyState
                } else if searches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], spacing: 16) {
                        ForEach(searches) { search in
                            AppointmentSearchCard(search: search, reload: load)
                                .contextMenu { menu(for: search) }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No searches yet", systemImage: "stethoscope")
        } description: {
            Text("A search watches Doctolib and jameda for a speciality near a place and tells you when an appointment frees up.")
        } actions: {
            if family.canEdit {
                Button("New search", systemImage: "plus") { creating = true }
                    .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .contentCard()
    }

    @ViewBuilder private func menu(for search: AppointmentSearch) -> some View {
        Button("Open", systemImage: "arrow.right.circle") { pushed = .search(search.id) }
        Button("History", systemImage: "clock.arrow.circlepath") { pushed = .history(search.id) }
        if family.canEdit {
            Divider()
            Button("Run now", systemImage: "arrow.clockwise") {
                perform {
                    try await AppointmentActions.runNow(family, search.id)
                    await load()
                }
            }
            .disabled(search.isBusy)
            Button("Edit", systemImage: "pencil") { editing = search }
            Button(search.enabled ? "Pause" : "Resume", systemImage: search.enabled ? "pause.circle" : "play.circle") {
                perform { try await AppointmentActions.setEnabled(family, search.id, !search.enabled) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = search }
        }
    }

    // MARK: Booked appointments (booked-list.tsx)

    private func bookedSection(_ events: [AppointmentEvent]) -> some View {
        CardSection("Booked appointments", systemImage: "calendar.badge.checkmark", tint: ModuleTint.appointments) {
            Button("Calendar", systemImage: "calendar") { family.open(.module(.calendar)) }
                .font(.subheadline)
                .buttonStyle(.glass)
        } content: {
            Text("Slots you marked as booked; they show in the calendar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { Divider() }
                AppointmentBookedRow(event: event, canEdit: family.canEdit, open: { pushed = $0 },
                                     showDay: { family.open($0) }) { removing = event }
            }
        }
    }
}

/// One booked appointment: when, the doctor (to its search), for whom and where.
struct AppointmentBookedRow: View {
    let event: AppointmentEvent
    let canEdit: Bool
    let open: (AppointmentRoute) -> Void
    /// Opens the event's day in the calendar.
    let showDay: (AppRoute) -> Void
    let remove: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    showDay(AppointmentLogic.calendarRoute(date: event.date))
                } label: {
                    Text(AppointmentLogic.formatBooking(date: event.date, start: event.start))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ModuleTint.appointments)
                }
                .buttonStyle(.plain)
                .help("Show in calendar")
                title
                if !event.location.isEmpty {
                    Label(event.location, systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url = AppointmentLogic.safeURL(event.url) {
                Button("Book", systemImage: "arrow.up.right.square") { openURL(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Open the provider’s page")
            }
            if canEdit {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Remove")
            }
        }
        .contextMenu {
            if let searchId = event.searchId {
                Button("Open search", systemImage: "magnifyingglass") { open(.search(searchId)) }
            }
            Button("Show in calendar", systemImage: "calendar") { showDay(AppointmentLogic.calendarRoute(date: event.date)) }
            if canEdit {
                Button("Remove", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }

    @ViewBuilder private var title: some View {
        HStack(spacing: 4) {
            if let searchId = event.searchId {
                NavigationLink(value: AppointmentRoute.search(searchId)) {
                    Text(event.title).font(.body.weight(.medium))
                }
                .buttonStyle(.plain)
            } else {
                Text(event.title).font(.body.weight(.medium))
            }
            if !event.person.isEmpty {
                Text(verbatim: "· \(event.person)").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}

/// A search as a glass card (search-list.tsx `SearchCard`): name, criteria, status, schedule,
/// last run, the first three doctors, "run now".
struct AppointmentSearchCard: View {
    @Environment(FamilyContext.self) private var family
    let search: AppointmentSearch
    let reload: () async -> Void

    private static let inline = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: AppointmentRoute.search(search.id)) { header }
                .buttonStyle(.plain)

            if search.hasError, let run = search.latestRun {
                AppointmentRunMessage(run: run, lineLimit: 3)
            }

            let shown = Array(search.doctors.prefix(Self.inline))
            if shown.isEmpty {
                Text(search.latestRun == nil ? "Not run yet: results appear after the first run." : "No bookable appointments in the latest run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(shown) { doctor in
                        NavigationLink(value: AppointmentRoute.slot(searchID: search.id, resultID: doctor.resultId)) {
                            AppointmentDoctorRow(doctor: doctor)
                        }
                        .buttonStyle(.plain)
                    }
                }
                let more = search.doctors.count - shown.count
                if more > 0 {
                    NavigationLink(value: AppointmentRoute.search(search.id)) {
                        Text(AppointmentLogic.moreDoctors(more))
                            .font(.subheadline)
                            .foregroundStyle(ModuleTint.appointments)
                    }
                    .buttonStyle(.plain)
                }
            }

            if family.canEdit {
                AppointmentRunNowButton(search: search, reload: reload)
            }
        }
        .contentCard(tint: search.hasError ? .red : nil)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if search.hasError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(search.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(AppointmentLogic.criteriaSummary(search))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if let status = search.badgeStatus { AppointmentStatusBadge(status: status) }
                if !search.enabled { AppointmentPausedBadge() }
                Text(verbatim: "\(AppointmentLogic.scheduleSummary(search)) · \(AppointmentActions.lastRunText(search))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(.rect)
    }
}

/// "Run now": queues the search for the worker; spins while queued or running.
struct AppointmentRunNowButton: View {
    @Environment(FamilyContext.self) private var family
    let search: AppointmentSearch
    let reload: () async -> Void
    var prominent = false
    @State private var sending = false

    var body: some View {
        let busy = sending || search.isBusy
        Button {
            sending = true
            perform {
                defer { sending = false }
                try await AppointmentActions.runNow(family, search.id)
                await reload()
            }
        } label: {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(busy ? "Running…" : "Run now")
            }
        }
        .disabled(busy)
        .modifier(AppointmentButtonStyle(prominent: prominent))
    }
}

/// `.glassProminent` or `.glass`.
struct AppointmentButtonStyle: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

/// The module's changes, shared by its screens. Each tells the other screens what changed.
enum AppointmentActions {
    static func runNow(_ family: FamilyContext, _ searchID: String) async throws {
        try await family.api.perform(.post, "/appointments/searches/\(searchID)/run")
        ErrorBanner.shared.success(String(localized: "Queued: the search runs in a few seconds."))
    }

    static func setEnabled(_ family: FamilyContext, _ searchID: String, _ enabled: Bool) async throws {
        try await family.api.perform(.post, "/appointments/searches/\(searchID)/enabled", body: ["enabled": enabled])
        family.didChange(.appointments)
    }

    static func delete(_ family: FamilyContext, _ searchID: String) async throws {
        try await family.api.perform(.delete, "/appointments/searches/\(searchID)")
        family.didChange(.appointments, .events, .calendar)
        ErrorBanner.shared.success(String(localized: "Search deleted."))
    }

    static func ignore(_ family: FamilyContext, resultID: Int) async throws {
        try await family.api.perform(.post, "/appointments/results/\(resultID)/ignore")
        family.didChange(.appointments)
        ErrorBanner.shared.success(String(localized: "Ignored."))
    }

    static func unignore(_ family: FamilyContext, entryID: Int) async throws {
        try await family.api.perform(.delete, "/appointments/ignored/\(entryID)")
        family.didChange(.appointments)
        ErrorBanner.shared.success(String(localized: "Removed from the ignore list."))
    }

    static func removeBooking(_ family: FamilyContext, _ eventID: String) async throws {
        try await family.api.perform(.delete, "/appointments/bookings/\(eventID)")
        family.didChange(.appointments, .events, .calendar)
        ErrorBanner.shared.success(String(localized: "Appointment removed."))
    }

    /// "last run 3 Nov 2026 at 09:30" or "never run".
    static func lastRunText(_ search: AppointmentSearch) -> String {
        guard let last = search.lastRunAt else { return String(localized: "never run") }
        let date = AppointmentLogic.formatSlot(last)
        return String(localized: "last run \(date)")
    }

    /// "next run …" of an enabled interval search.
    static func nextRunText(_ search: AppointmentSearch) -> String? {
        guard search.enabled, let next = search.nextRunAt else { return nil }
        let date = AppointmentLogic.formatSlot(next)
        return String(localized: "next run \(date)")
    }
}

/// The screen of a route.
struct AppointmentRouteView: View {
    let route: AppointmentRoute

    var body: some View {
        switch route {
        case let .search(id): AppointmentSearchDetailView(searchID: id)
        case let .history(id): AppointmentHistoryView(searchID: id)
        case let .slot(searchID, resultID): AppointmentSlotView(searchID: searchID, resultID: resultID)
        }
    }
}
