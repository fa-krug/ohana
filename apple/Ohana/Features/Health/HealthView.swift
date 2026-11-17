import SwiftUI

/// Check-ups and vaccinations (server/lib/health): what's due now across the family, then each
/// member with what's next. Everything comes from the birthdays: nobody types in a schedule. A due
/// item is ticked off with one swipe ("Done today"), or opened to pick its date; a member's page
/// lists their check-ups (U1–U11, J1, J2) and vaccinations, marks every earlier one done at once
/// and reads their booklet (Impfpass, U-Heft) with the camera. Editors see everyone, a viewer
/// themselves. A notification's `/f/{id}/health/{memberId}` opens that member.
struct HealthView: View {
    @Environment(FamilyContext.self) private var family
    @State private var store = HealthStore()
    @State private var pushed: HealthMemberRoute?
    @State private var editing: HealthEditTarget?

    var body: some View {
        LoadStateView(state: store.state, retry: load) { overview in
            content(overview)
        }
        .ohanaBackground(ModuleTint.health)
        .navigationTitle("Health")
        .environment(store)
        .task(id: [family.revision(.health), family.revision(.family)]) { await load() }
        .navigationDestination(for: HealthMemberRoute.self) {
            HealthMemberView(memberID: $0.id).environment(store).shellPageItems()
        }
        .navigationDestination(item: $pushed) {
            HealthMemberView(memberID: $0.id).environment(store).id($0).shellPageItems()
        }
        .onChange(of: family.pendingRoute, initial: true) {
            guard let route = family.takeRoute(for: .health) else { return }
            if case let .healthMember(id) = route { pushed = HealthMemberRoute(id: id) } else { pushed = nil }
        }
        .sheet(item: $editing) { target in
            HealthRecordSheet(target: target).environment(store)
        }
    }

    private func load() async {
        await store.load(family)
    }

    @ViewBuilder private func content(_ overview: HealthOverview) -> some View {
        let due = overview.members.flatMap { member in member.due.map { HealthEditTarget(member: member, item: $0) } }
            .sorted { ($0.item.until ?? .distant) < ($1.item.until ?? .distant) }
        List {
            if overview.members.allSatisfy({ $0.birthday == nil }) {
                Section {
                    ContentUnavailableView {
                        Label("No birthdays yet", systemImage: "birthday.cake")
                    } description: {
                        Text("Check-ups and vaccinations are worked out from birthdays.")
                            + Text(verbatim: " ") + Text("Add them to the family’s members.")
                    } actions: {
                        Button("Members") { family.open(.settings(.members)) }
                            .buttonStyle(.glassProminent)
                    }
                }
            }

            if !due.isEmpty {
                Section {
                    ForEach(due) { target in
                        HealthDueRow(member: target.member, item: target.item, edit: { editing = target })
                    }
                } header: {
                    Text("Due now")
                }
            }

            Section {
                ForEach(overview.members) { member in
                    NavigationLink(value: HealthMemberRoute(id: member.id)) {
                        HealthMemberRow(member: member)
                    }
                }
            } header: {
                Text(overview.members.count == 1 ? "You" : "Family")
            } footer: {
                HealthFooter(asOf: overview.asOf)
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .readableWidth()
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
    }
}

struct HealthMemberRoute: Hashable, Identifiable {
    let id: String
}

/// An item to record or change, for whom.
struct HealthEditTarget: Identifiable {
    let member: HealthMember
    let item: HealthItem

    var id: String { "\(member.id)|\(item.code)" }
}

private extension Day {
    /// Sorts after every real day.
    static let distant = Day(year: 9999, month: 12, day: 31)
}

/// "As of STIKO 2025 · G-BA 2025": the booklets are what counts.
struct HealthFooter: View {
    let asOf: String

    var body: some View {
        Text("Worked out from the birthdays (\(asOf)).") + Text(verbatim: " ")
            + Text("The vaccination booklet, the U-Heft and your doctor decide; Ohana only reminds.")
    }
}

/// A due item across the family: who, what, until when; a leading swipe records it as done today.
private struct HealthDueRow: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    let member: HealthMember
    let item: HealthItem
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 12) {
                MemberIcon(name: member.name, color: member.color, photo: member.photo, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(item.title) · \(member.name)").fontWeight(.medium)
                    Text(HealthText.line(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if member.canEdit, store.canChange {
                Button("Done Today", systemImage: "checkmark") { doneToday() }
                    .tint(.green)
            }
        }
        .contextMenu {
            HealthItemMenu(member: member, item: item, edit: edit)
        }
    }

    private func doneToday() {
        perform { try await store.doneToday(family, member: member.id, code: item.code) }
    }
}

/// What an item's context menu offers: done today, pick the date, skip, find an appointment.
struct HealthItemMenu: View {
    @Environment(FamilyContext.self) private var family
    @Environment(HealthStore.self) private var store
    let member: HealthMember
    let item: HealthItem
    let edit: () -> Void

    var body: some View {
        if member.canEdit, store.canChange {
            if !item.status.isRecorded || item.repeats {
                Button("Done Today", systemImage: "checkmark") {
                    perform { try await store.doneToday(family, member: member.id, code: item.code) }
                }
            }
            Button(item.status.isRecorded ? "Edit…" : "Done on…" as LocalizedStringKey,
                   systemImage: "calendar", action: edit)
            if item.status == .due || item.status == .past {
                Button("Skip", systemImage: "minus.circle") {
                    perform {
                        try await store.record(family, member: member.id,
                                               [HealthRecordInput(code: item.code, day: nil, status: "skipped")])
                    }
                }
            }
        }
        if item.status == .due, HealthBooking.canBook(family) {
            Divider()
            Button("Find an Appointment", systemImage: "stethoscope") {
                HealthBooking.book(family, member: member, item: item)
            }
        }
    }
}

/// A member: avatar, name and age, and what's next (or what's missing).
private struct HealthMemberRow: View {
    let member: HealthMember

    var body: some View {
        HStack(spacing: 12) {
            MemberIcon(name: member.name, color: member.color, photo: member.photo, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.name).fontWeight(.medium)
                    if let age = member.age() {
                        Text(String(localized: "\(age) years")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                subtitle
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if member.counts.due > 0 {
                Text(member.counts.due, format: .number)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.orange, in: .capsule)
                    .accessibilityLabel(Text("\(member.counts.due) due"))
            }
        }
    }

    private var subtitle: Text {
        if member.birthday == nil { return Text("Add a birthday to see check-ups and vaccinations") }
        guard let next = member.next else {
            if member.counts.unknown > 0 { return Text("When was the last tetanus shot?") }
            return Text("Nothing due")
        }
        return Text(verbatim: "\(next.title) · \(HealthText.line(next))")
    }
}
