import CoreGraphics
import SwiftUI

/// The health page's data (`GET /health`), shared by the page, a member's page and the sheets:
/// each change answers with the member's new state, which replaces theirs here at once; the
/// other screens hear of it through `didChange(.health)`.
@MainActor @Observable
final class HealthStore {
    var state: LoadState<HealthOverview> = .idle

    var overview: HealthOverview? { state.value }

    func member(_ id: String) -> HealthMember? {
        overview?.members.first { $0.id == id }
    }

    /// Changes wait while what's shown is the copy on the device.
    var canChange: Bool { !state.isSaved }

    // MARK: Loading

    /// The page's GET (the prefetch asks the same): filed without `today`, like the overview.
    static func request(_ api: FamilyAPI) -> CachedGet<HealthOverview> {
        api.cached("/health", query: query, key: "/health")
    }

    /// The day the windows are worked out for and the titles' language.
    static var query: [String: String?] {
        ["today": Day.today.description, "lang": MealPlanLanguage.current]
    }

    func load(_ family: FamilyContext) async {
        let binding = Binding(get: { self.state }, set: { self.state = $0 })
        await LoadState.run(binding, Self.request(family.api))
    }

    // MARK: Changes

    private struct RecordsBody: Encodable {
        let memberId: String
        let records: [HealthRecordInput]
    }

    private struct MemberBody: Encodable {
        let memberId: String
    }

    private struct PatchBody: Encodable {
        let day: Day?
        let status: String
        let note: String

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let day { try c.encode(day, forKey: .day) } else { try c.encodeNil(forKey: .day) }
            try c.encode(status, forKey: .status)
            try c.encode(note, forKey: .note)
        }

        private enum CodingKeys: String, CodingKey { case day, status, note }
    }

    private struct ScanBody: Encodable {
        let memberId: String
        let pages: [String]
    }

    /// Saves records for a member (a check-up recorded once replaces its earlier record).
    func record(_ family: FamilyContext, member: String, _ records: [HealthRecordInput]) async throws {
        guard !records.isEmpty else { return }
        let change: HealthChange = try await family.api.send(
            .post, "/health/records", query: Self.query, body: RecordsBody(memberId: member, records: records))
        apply(change.member, family)
    }

    /// Changes a record's day (nil: unknown), status and note.
    func update(_ family: FamilyContext, record: String, day: Day?, status: HealthStatus, note: String) async throws {
        let change: HealthChange = try await family.api.send(
            .patch, "/health/records/\(record)", query: Self.query,
            body: PatchBody(day: day, status: status == .skipped ? "skipped" : "done", note: note))
        apply(change.member, family)
    }

    func delete(_ family: FamilyContext, record: String) async throws {
        let change: HealthChange = try await family.api.send(.delete, "/health/records/\(record)", query: Self.query)
        apply(change.member, family)
    }

    /// Every child's window that closed without a record: done, date unknown.
    func markPastDone(_ family: FamilyContext, member: String) async throws {
        let change: HealthChange = try await family.api.send(
            .post, "/health/past", query: Self.query, body: MemberBody(memberId: member))
        apply(change.member, family)
    }

    /// Asks the family's AI what a booklet's pages say (nothing is saved).
    func scan(_ family: FamilyContext, member: String, pages: [String]) async throws -> HealthScanAnswer {
        try await family.api.send(.post, "/health/scan", query: Self.query, body: ScanBody(memberId: member, pages: pages))
    }

    private func apply(_ member: HealthMember, _ family: FamilyContext) {
        if case var .loaded(overview) = state, let i = overview.members.firstIndex(where: { $0.id == member.id }) {
            overview.members[i] = member
            withAnimation(.snappy) { state = .loaded(overview) }
        }
        family.didChange(.health)
    }
}

/// A booklet's pages as the server takes them: cropped to the paper when picked, upright JPEGs of
/// at most 2000 px and 4 MB, base64.
nonisolated enum HealthScanPages {
    static let maxPages = 8

    @concurrent
    static func encode(_ images: [CGImage], crop: Bool) async -> [String] {
        let pages = crop ? await ScanCrop.cropped(images) : images
        return pages.prefix(maxPages).compactMap { KnowledgeOCR.scanJPEG($0, orientation: .up)?.base64EncodedString() }
    }
}

/// Finding an appointment for a due item: the assistant (it starts an appointment search), else a
/// new search of the appointments page.
enum HealthBooking {
    @MainActor
    static func canBook(_ family: FamilyContext) -> Bool {
        family.canEdit && !family.api.client.isDemo
            && (family.isEnabled(.assistant) || family.isEnabled(.appointments))
    }

    @MainActor
    static func book(_ family: FamilyContext, member: HealthMember, item: HealthItem) {
        guard family.isEnabled(.assistant) else {
            family.open(.newAppointmentSearch)
            return
        }
        let child = (member.age() ?? 0) < 18
        let until = item.until.map { HealthText.date($0) }
        let prompt: String
        switch (child, until) {
        case let (true, until?):
            prompt = String(localized: "Find an appointment at a pediatrician for \(member.name)’s \(item.title), before \(until).")
        case (true, nil):
            prompt = String(localized: "Find an appointment at a pediatrician for \(member.name)’s \(item.title).")
        case let (false, until?):
            prompt = String(localized: "Find an appointment at a family doctor for \(member.name)’s \(item.title), before \(until).")
        case (false, nil):
            prompt = String(localized: "Find an appointment at a family doctor for \(member.name)’s \(item.title).")
        }
        family.ask(prompt, send: true, newChat: true)
    }
}
