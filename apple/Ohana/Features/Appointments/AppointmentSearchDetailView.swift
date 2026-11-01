import SwiftUI

/// One search (search-detail.tsx): its criteria, schedule and last run, "run now" (polling until
/// the worker is done), the earliest slot per doctor by day with the distance from home, the
/// ignore list; editors edit, pause, delete. Its commands are in the Appointments menu too while
/// it's on screen.
struct AppointmentSearchDetailView: View {
    @Environment(FamilyContext.self) private var family
    @Environment(\.dismiss) private var dismiss
    let searchID: String
    @State private var state: LoadState<AppointmentSearchDetail> = .idle
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var width: CGFloat = 0
    /// Deleted here: no more reloads (they'd answer 404) while the page goes away.
    @State private var deleted = false
    /// On screen (not covered by a pushed page): only then it sets the module menu.
    @State private var onScreen = false

    /// Changes to what's shown wait while it's the copy on the device.
    private var canEdit: Bool { family.canEdit && !state.isSaved }

    var body: some View {
        LoadStateView(state: state, retry: load) { detail in
            content(detail)
        }
        .ohanaBackground(ModuleTint.appointments)
        .navigationTitle(state.value?.search.name ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .task(id: family.revision(.appointments)) { await load() }
        .appointmentPolling(busy: !state.isSaved && state.value?.search.isBusy == true) { await load() }
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
        .focusedSceneValue(\.moduleMenu, onScreen && canEdit ? state.value.map { menu($0.search) } : nil)
        .sheet(isPresented: $editing) {
            if let search = state.value?.search {
                AppointmentSearchEditor(search: search) { _ in }
            }
        }
        .confirmationDialog(Text("Delete “\(state.value?.search.name ?? "")”?"), isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete Search", role: .destructive) {
                perform {
                    deleted = true
                    do {
                        try await AppointmentActions.delete(family, searchID)
                    } catch {
                        deleted = false
                        throw error
                    }
                    dismiss()
                }
            }
        } message: {
            Text("Delete the search “\(state.value?.search.name ?? "")” with its history?")
        }
    }

    private func load() async {
        guard !deleted else { return }
        await LoadState.run($state, family.api.cached("/appointments/searches/\(searchID)"))
    }

    /// The Appointments menu (editors): Run Now ⌘R, Edit ⌘E, pause, Delete ⌘⌫.
    private func menu(_ search: AppointmentSearch) -> ModuleMenu {
        ModuleMenu(title: "Appointments") {
            Button("Run Now") {
                perform {
                    try await AppointmentActions.runNow(family, search.id)
                    await load()
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(search.isBusy)
            Button("Edit Search…") { editing = true }
                // ⌘E is the system's "Use Selection for Find".
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button(search.enabled ? "Pause Search" : "Resume Search") {
                perform { try await AppointmentActions.setEnabled(family, search.id, !search.enabled) }
            }
            Divider()
            Button("Delete Search…") { confirmDelete = true }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let search = state.value?.search {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink(value: AppointmentRoute.history(search.id)) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .help("History")
            }
            if canEdit {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit", systemImage: "pencil") { editing = true }
                        .help("Edit (⌘E)")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("More", systemImage: "ellipsis") {
                        Toggle(isOn: Binding(get: { search.enabled }, set: { value in
                            perform { try await AppointmentActions.setEnabled(family, search.id, value) }
                        })) {
                            Label("Check automatically", systemImage: "clock")
                        }
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    }
                }
            }
        }
    }

    @ViewBuilder private func content(_ detail: AppointmentSearchDetail) -> some View {
        let search = detail.search
        ScrollView {
            Group {
                if width >= 820 {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { results(detail) }
                            .frame(maxWidth: .infinity)
                        VStack(spacing: 20) {
                            summary(search)
                            ignored(search)
                        }
                        .frame(width: 360)
                    }
                } else {
                    VStack(spacing: 20) {
                        summary(search)
                        results(detail)
                        ignored(search)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .refreshable { await load() }
    }

    // MARK: Header card

    private func summary(_ search: AppointmentSearch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let status = search.badgeStatus { AppointmentStatusBadge(status: status) }
                if !search.enabled { AppointmentPausedBadge() }
            }
            Text(search.name)
                .font(.title2.weight(.semibold))
            Text(AppointmentLogic.criteriaSummary(search))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppointmentLogic.scheduleSummary(search))
                if let next = AppointmentActions.nextRunText(search) { Text(next) }
                Text(AppointmentActions.lastRunText(search))
                if let run = search.latestRun, run.status != "RUNNING" {
                    AppointmentRunCounts(run: run)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let run = search.latestRun, run.status != "RUNNING" {
                AppointmentRunMessage(run: run)
            }
            if canEdit {
                AppointmentRunNowButton(search: search, reload: load, prominent: true)
                    .help("Run now (⌘R)")
            }
        }
        .contentCard()
    }

    // MARK: Results by day

    @ViewBuilder private func results(_ detail: AppointmentSearchDetail) -> some View {
        let search = detail.search
        CardSection("Earliest appointment per doctor", systemImage: "calendar.badge.clock", tint: ModuleTint.appointments) {
            if search.doctors.isEmpty {
                Text(search.latestRun == nil ? "Not run yet: results appear after the first run." : "No bookable appointments in the latest run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let groups = AppointmentLogic.groupedByDay(search.doctors)
                ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                    if index > 0 { Divider() }
                    Text(group.day?.formatted(.dateTime.weekday(.wide).day().month(.wide)) ?? "—")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(group.slots) { doctor in
                        NavigationLink(value: AppointmentRoute.slot(searchID: search.id, resultID: doctor.resultId)) {
                            AppointmentDoctorRow(
                                doctor: doctor,
                                distance: AppointmentLogic.distance(of: doctor, homeLat: detail.home?.lat, homeLng: detail.home?.lng),
                                showDate: false
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu { slotMenu(doctor) }
                    }
                }
            }
        }
    }

    @Environment(\.openURL) private var openURL

    @ViewBuilder private func slotMenu(_ doctor: AppointmentDoctorSlot) -> some View {
        if let url = doctor.bookingURL {
            Button("Book on \(doctor.sourceName)", systemImage: "arrow.up.right.square") { openURL(url) }
        }
        if canEdit {
            Button("Ignore", systemImage: "eye.slash") {
                perform { try await AppointmentActions.ignore(family, resultID: doctor.resultId) }
            }
        }
    }

    // MARK: Ignore list

    private func ignored(_ search: AppointmentSearch) -> some View {
        CardSection("Ignore list", systemImage: "eye.slash") {
            Text("Doctors (with their reason for the visit) this search skips. Ignore one from its appointment page.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if search.ignored.isEmpty {
                Text("Nothing ignored.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(search.ignored) { entry in
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            ignoredEntry(entry)
                            Spacer()
                            showAgain(entry)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ignoredEntry(entry)
                            showAgain(entry)
                        }
                    }
                }
            }
        }
    }

    private func ignoredEntry(_ entry: AppointmentIgnoredItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.doctorName.isEmpty ? entry.providerSlug : entry.doctorName)
            if !entry.motiveLabel.isEmpty {
                Text(entry.motiveLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func showAgain(_ entry: AppointmentIgnoredItem) -> some View {
        if canEdit {
            Button("Show again", systemImage: "eye") {
                perform { try await AppointmentActions.unignore(family, entryID: entry.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

/// Every run of a search with what it found (history-list.tsx).
struct AppointmentHistoryView: View {
    @Environment(FamilyContext.self) private var family
    let searchID: String
    @State private var state: LoadState<[AppointmentRunWithResults]> = .idle

    var body: some View {
        LoadStateView(state: state, retry: load) { runs in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Every run of this search with what it found. Runs older than 30 days are deleted.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    if runs.isEmpty {
                        ContentUnavailableView("No runs yet.", systemImage: "clock")
                    }
                    ForEach(runs) { item in
                        runCard(item)
                    }
                }
                .padding()
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await load() }
        }
        .ohanaBackground(ModuleTint.appointments)
        .navigationTitle("History")
        .task(id: family.revision(.appointments)) { await load() }
        .appointmentPolling(busy: !state.isSaved && state.value?.contains { $0.run.status == "RUNNING" } == true) { await load() }
    }

    private func load() async {
        await LoadState.run($state, family.api.cached("/appointments/searches/\(searchID)/runs",
                                                      as: AppointmentRunsResponse.self)) { $0.runs }
    }

    private func runCard(_ item: AppointmentRunWithResults) -> some View {
        let run = item.run
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppointmentStatusBadge(status: run.status)
                Text(AppointmentLogic.formatSlot(run.startedAt))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                Text(run.triggeredBy == "MANUAL" ? "started by hand" : "scheduled")
                Text(verbatim: "·")
                AppointmentRunCounts(run: run)
                if run.notified {
                    Text(verbatim: "·")
                    Text("notified")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            AppointmentRunMessage(run: run)
            ForEach(item.doctors) { doctor in
                NavigationLink(value: AppointmentRoute.slot(searchID: searchID, resultID: doctor.resultId)) {
                    AppointmentDoctorRow(doctor: doctor)
                }
                .buttonStyle(.plain)
            }
        }
        .contentCard()
    }
}
