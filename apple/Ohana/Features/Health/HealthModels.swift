import SwiftUI

/// GET /api/v1/families/{id}/health?today=&lang= (server/lib/health): the members the account may
/// see (editors everyone, a viewer themselves) with their check-ups (U1–U11, J1, J2) and
/// vaccinations, worked out by the server from their birthdays. Decoded leniently: what a newer
/// server adds (a status, a kind) still shows.
nonisolated struct HealthOverview: Codable, Hashable, OffMainDecodable {
    var members: [HealthMember]
    /// An editor (sees and records everyone's).
    var canEdit: Bool
    /// The family's AI can read a booklet's pages (`POST /health/scan`).
    var scan: Bool
    /// Which edition of the recommendations ("STIKO 2025 · G-BA 2025").
    var asOf: String
}

nonisolated extension HealthOverview {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = try container.decodeIfPresent([HealthMember].self, forKey: .members) ?? []
        canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
        scan = try container.decodeIfPresent(Bool.self, forKey: .scan) ?? false
        asOf = try container.decodeIfPresent(String.self, forKey: .asOf) ?? ""
    }
}

/// A member (an account or a person without one) with their items.
nonisolated struct HealthMember: Codable, Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    var account: Bool
    var birthday: Day?
    var color: String?
    var photo: String?
    /// The account may record for them.
    var canEdit: Bool
    var items: [HealthItem]
    /// What to do next: the open window closing first, else the next to open.
    var next: HealthItem?
    var counts: HealthCounts
}

nonisolated extension HealthMember {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        account = try container.decodeIfPresent(Bool.self, forKey: .account) ?? false
        birthday = try? container.decodeIfPresent(Day.self, forKey: .birthday)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        photo = try container.decodeIfPresent(String.self, forKey: .photo)
        canEdit = try container.decodeIfPresent(Bool.self, forKey: .canEdit) ?? false
        items = try container.decodeIfPresent([HealthItem].self, forKey: .items) ?? []
        next = try container.decodeIfPresent(HealthItem.self, forKey: .next)
        counts = try container.decodeIfPresent(HealthCounts.self, forKey: .counts) ?? HealthCounts()
    }

    /// Full years on `today`.
    func age(on today: Day = .today) -> Int? {
        guard let birthday else { return nil }
        var years = today.year - birthday.year
        if (today.month, today.day) < (birthday.month, birthday.day) { years -= 1 }
        return years
    }

    var checkups: [HealthItem] { items.filter { $0.kind == .checkup } }
    var vaccinations: [HealthItem] { items.filter { $0.kind != .checkup } }
    var due: [HealthItem] { items.filter { $0.status == .due } }
    /// Children's windows that closed without a record.
    var past: [HealthItem] { items.filter { $0.status == .past } }
}

nonisolated struct HealthCounts: Codable, Hashable, Sendable {
    var due = 0
    var past = 0
    var unknown = 0
}

nonisolated enum HealthKind: String, Codable, Hashable, Sendable {
    case checkup, vaccination

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HealthKind(rawValue: raw) ?? .vaccination
    }
}

/// Where someone stands with an item.
nonisolated enum HealthStatus: String, Codable, Hashable, Sendable {
    /// Recorded.
    case done, skipped
    /// Its window is open.
    case due
    /// Its window opens later.
    case upcoming
    /// A child's window closed without a record: shown quietly as "not recorded".
    case past
    /// Never recorded (when was the last tetanus shot?), or a second dose whose first has no date.
    case unknown
    /// Not recommended at this age but can be had (flu, COVID-19 before 60). Once recorded it's
    /// due again each autumn (until a season is skipped).
    case optional

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HealthStatus(rawValue: raw) ?? .unknown
    }

    var isRecorded: Bool { self == .done || self == .skipped }
}

/// One check-up or vaccination visit of the schedule, for one member.
nonisolated struct HealthItem: Codable, Hashable, Identifiable, Sendable {
    let code: String
    var kind: HealthKind
    var title: String
    var detail: String
    var vaccines: [String]
    /// U10, U11, J2: not paid by every health insurer.
    var notAlwaysPaid: Bool
    var status: HealthStatus
    /// The window (its last day `until`); a repeating one's `from` is when it's due next.
    var from: Day?
    var until: Day?
    /// Tetanus (every 10 years), flu and COVID-19 (each autumn).
    var repeats: Bool
    /// Not recommended at this age but can be had (flu, COVID-19 before 60).
    var optional: Bool
    /// Newest first.
    var records: [HealthRecord]

    var id: String { code }
}

nonisolated extension HealthItem {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        kind = try container.decodeIfPresent(HealthKind.self, forKey: .kind) ?? .vaccination
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? code
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        vaccines = try container.decodeIfPresent([String].self, forKey: .vaccines) ?? []
        notAlwaysPaid = try container.decodeIfPresent(Bool.self, forKey: .notAlwaysPaid) ?? false
        status = try container.decodeIfPresent(HealthStatus.self, forKey: .status) ?? .unknown
        from = try? container.decodeIfPresent(Day.self, forKey: .from)
        until = try? container.decodeIfPresent(Day.self, forKey: .until)
        repeats = try container.decodeIfPresent(Bool.self, forKey: .repeats) ?? false
        optional = try container.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        records = try container.decodeIfPresent([HealthRecord].self, forKey: .records) ?? []
    }

    /// The record of a check-up or visit recorded once (a repeating one's newest).
    var latest: HealthRecord? { records.first }
}

/// A check-up or vaccination someone had (or skipped).
nonisolated struct HealthRecord: Codable, Hashable, Identifiable, Sendable {
    let id: String
    /// When; nil: done, the date isn't known.
    var day: Day?
    var status: HealthStatus
    var note: String
}

nonisolated extension HealthRecord {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        day = try? container.decodeIfPresent(Day.self, forKey: .day)
        status = try container.decodeIfPresent(HealthStatus.self, forKey: .status) ?? .done
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// What a change answers: the member's new state (and for undo what it replaced).
nonisolated struct HealthChange: Decodable, Sendable, OffMainDecodable {
    var member: HealthMember
}

/// A record to save (`POST /health/records`).
nonisolated struct HealthRecordInput: Encodable, Hashable, Sendable {
    var code: String
    /// nil: done, the date isn't known.
    var day: Day?
    var status: String = "done"
    var note: String = ""

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(day, forKey: .day)
        try container.encode(status, forKey: .status)
        try container.encode(note, forKey: .note)
    }

    private enum CodingKeys: String, CodingKey { case code, day, status, note }
}

/// A suggestion read from a booklet's pages (`POST /health/scan`).
nonisolated struct HealthScanSuggestion: Codable, Hashable, Identifiable, Sendable {
    var code: String
    var title: String
    var day: Day?
    var note: String
    /// Recorded like this already.
    var known: Bool

    var id: String { "\(code)|\(day?.description ?? "")" }
}

nonisolated extension HealthScanSuggestion {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? code
        day = try? container.decodeIfPresent(Day.self, forKey: .day)
        note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        known = try container.decodeIfPresent(Bool.self, forKey: .known) ?? false
    }
}

nonisolated struct HealthScanAnswer: Decodable, Sendable, OffMainDecodable {
    /// The family's AI is set up (else nothing was read).
    var readable: Bool
    var items: [HealthScanSuggestion]
}

nonisolated extension HealthScanAnswer {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        readable = try container.decodeIfPresent(Bool.self, forKey: .readable) ?? false
        items = try container.decodeIfPresent([HealthScanSuggestion].self, forKey: .items) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case readable = "ai"
        case items
    }
}
