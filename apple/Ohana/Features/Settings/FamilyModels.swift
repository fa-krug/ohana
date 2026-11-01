import Foundation
import SwiftUI
import UniformTypeIdentifiers

// The shapes of server/lib/families/app-routes.ts (GET /household and the changes under it).

/// GET /api/v1/families/{id}/household
struct FamilyHousehold: Codable, Hashable {
    let name: String
    let role: FamilyRole
    let selfId: String
    let members: [FamilyMember]
    let people: [FamilyPerson]
    /// Open invites; empty for viewers.
    let invites: [FamilyInvite]
    let home: FamilyHome
    let channels: [FamilyChannel]
    var events: [FamilyEventPref]

    var canEdit: Bool { role == .editor }

    /// The open invite for a member without an account, if any.
    func invite(for person: FamilyPerson) -> FamilyInvite? {
        invites.first { $0.personId == person.id }
    }

    func person(_ id: String?) -> FamilyPerson? {
        guard let id else { return nil }
        return people.first { $0.id == id }
    }
}

/// server/lib/families/members.ts `MemberDto`.
struct FamilyMember: Codable, Hashable, Identifiable {
    let userId: String
    let email: String
    let name: String
    let role: FamilyRole
    let birthday: Day?
    let joinedAt: String

    var id: String { userId }
    var label: String { name.isEmpty ? email : name }
}

/// A member without an account (a child, a grandparent).
struct FamilyPerson: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let birthday: Day?
}

struct FamilyInvite: Codable, Hashable, Identifiable {
    let id: String
    let url: String
    let role: FamilyRole
    let personId: String?
    let expiresAt: String

    var link: URL? { URL(string: url) }
    var expiryDate: Date? { Date.server(expiresAt) }
}

/// POST /household/invites (and the invite of POST /household/people).
struct FamilyNewInvite: Codable, Hashable {
    let code: String
    let expiresAt: String
    let url: String
}

/// POST /household/people
struct FamilyAddedPerson: Codable, Hashable {
    let person: FamilyPerson
    let invite: FamilyNewInvite?
}

struct FamilyHome: Codable, Hashable {
    let address: String?
    let lat: Double?
    let lng: Double?

    var hasLocation: Bool { address != nil && lat != nil && lng != nil }
}

/// GET /api/v1/families/{id}/geocode?q= (server/lib/appointments/geocoding.ts).
struct FamilyLocationSuggestion: Codable, Hashable, Identifiable {
    let label: String
    let latitude: String
    let longitude: String

    var id: String { "\(label)|\(latitude)|\(longitude)" }
}

// MARK: Notifications

enum FamilyChannelProvider: String, Codable, CaseIterable, Identifiable {
    case pushbullet = "PUSHBULLET", pushover = "PUSHOVER", telegram = "TELEGRAM", ntfy = "NTFY", email = "EMAIL"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushbullet: "Pushbullet"
        case .pushover: "Pushover"
        case .telegram: "Telegram"
        case .ntfy: "ntfy"
        case .email: String(localized: "Email")
        }
    }

    var systemImage: String {
        switch self {
        case .pushbullet: "bell.badge"
        case .pushover: "bell.and.waves.left.and.right"
        case .telegram: "paperplane"
        case .ntfy: "antenna.radiowaves.left.and.right"
        case .email: "envelope"
        }
    }

    /// What the secret is called for this service.
    var tokenLabel: LocalizedStringKey {
        switch self {
        case .email: "SMTP password"
        case .telegram: "Bot token"
        case .ntfy: "Access token (optional)"
        default: "Access token / API key"
        }
    }

    /// What the target is called (Pushbullet has none).
    var targetLabel: LocalizedStringKey? {
        switch self {
        case .pushbullet: nil
        case .pushover: "User key"
        case .telegram: "Chat ID"
        case .ntfy: "Topic URL"
        case .email: "Recipient email"
        }
    }

    /// The fields the service needs (server/lib/notifications/schema.ts `CHANNEL_REQUIRED`); ntfy's
    /// token is for protected topics only.
    var required: [FamilyChannelField] {
        switch self {
        case .pushbullet: [.token]
        case .pushover, .telegram: [.token, .target]
        case .ntfy: [.target]
        case .email: [.smtpHost, .smtpUsername, .token, .target]
        }
    }
}

enum FamilyChannelField: String, Hashable {
    case token, target, smtpHost, smtpUsername
}

/// server/lib/notifications/channels.ts `ChannelDto` (the secret is never sent back).
struct FamilyChannel: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let provider: String
    let target: String
    let enabled: Bool
    let hasToken: Bool
    let smtpHost: String
    let smtpPort: Int
    let smtpUsername: String
    let smtpFrom: String

    var kind: FamilyChannelProvider? { FamilyChannelProvider(rawValue: provider) }
}

/// The body of POST / PATCH /household/notifications/channels (a blank token on edit keeps the
/// stored one).
struct FamilyChannelInput: Codable, Hashable {
    var name = ""
    var provider: FamilyChannelProvider = .pushbullet
    var token = ""
    var target = ""
    var smtpHost = ""
    var smtpPort = 465
    var smtpUsername = ""
    var smtpFrom = ""
    var enabled = true

    init() {}

    init(_ channel: FamilyChannel) {
        name = channel.name
        provider = channel.kind ?? .pushbullet
        target = channel.target
        smtpHost = channel.smtpHost
        smtpPort = channel.smtpPort
        smtpUsername = channel.smtpUsername
        smtpFrom = channel.smtpFrom
        enabled = channel.enabled
    }

    /// The required fields still empty; a stored token counts when `hasToken`.
    func missing(hasToken: Bool = false) -> [FamilyChannelField] {
        provider.required.filter { field in
            switch field {
            case .token: token.trimmingCharacters(in: .whitespaces).isEmpty && !hasToken
            case .target: target.trimmingCharacters(in: .whitespaces).isEmpty
            case .smtpHost: smtpHost.trimmingCharacters(in: .whitespaces).isEmpty
            case .smtpUsername: smtpUsername.trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    func canSave(hasToken: Bool = false) -> Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && missing(hasToken: hasToken).isEmpty
            && (1...65535).contains(smtpPort)
    }
}

/// server/lib/notifications/prefs-shared.ts `EventPref` with `hasChannels` (EVENT_HAS_CHANNELS).
struct FamilyEventPref: Codable, Hashable, Identifiable {
    let event: String
    var enabled: Bool
    /// nil: all of the family's enabled channels.
    var channelIds: [String]?
    /// Also pushed to the members' app devices; nil from a server without push to the app.
    var app: Bool?
    let hasChannels: Bool

    var id: String { event }

    /// The module the event belongs to (hidden when the server has it off); nil for unknown ones.
    var module: Module? {
        switch event {
        case "appointment_found": .appointments
        case "coverage_gap": .calendar
        case "shopping_reminder": .meals
        case "assistant_turn_finished": .assistant
        default: nil
        }
    }

    var title: LocalizedStringKey {
        switch event {
        case "appointment_found": "Appointment found"
        case "coverage_gap": "Day without cover"
        case "shopping_reminder": "Shopping reminder"
        case "assistant_turn_finished": "Assistant finished"
        default: LocalizedStringKey(event)
        }
    }

    var hint: LocalizedStringKey {
        switch event {
        case "appointment_found":
            "When a search finds a new or earlier appointment. Each search chooses its channels."
        case "coverage_gap":
            "In the morning, when a weekday in the next two weeks needs cover (e.g. a day-care closure) and nobody covers it yet."
        case "shopping_reminder":
            "In the evening before a shopping day: what is still on its list."
        case "assistant_turn_finished":
            "When the assistant worked on a request for a while (30 seconds or more) and the chat isn’t open anywhere."
        default: LocalizedStringKey(String())
        }
    }

    /// With `channel` turned on or off (from "all channels", that is every channel but it).
    func toggling(_ channel: String, on: Bool, all: [String]) -> FamilyEventPref {
        var ids = channelIds ?? all
        if on { if !ids.contains(channel) { ids.append(channel) } } else { ids.removeAll { $0 == channel } }
        var next = self
        next.channelIds = ids
        return next
    }

    /// The body of PUT /household/notifications/events/{event}: `channelIds` null means all.
    struct Input: Encodable {
        let enabled: Bool
        let channelIds: [String]?
        /// Left out when unknown: the server keeps it.
        let app: Bool?

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(enabled, forKey: .enabled)
            try c.encode(channelIds, forKey: .channelIds)
            try c.encodeIfPresent(app, forKey: .app)
        }

        private enum CodingKeys: String, CodingKey { case enabled, channelIds, app }
    }
    var input: Input { Input(enabled: enabled, channelIds: channelIds, app: app) }
}

// MARK: Bodies

struct FamilyNameInput: Codable { let name: String }
struct FamilyRoleInput: Codable { let role: FamilyRole }
struct FamilyInviteInput: Codable { let role: FamilyRole; let personId: String? }
struct FamilyAddMemberInput: Codable { let email: String; let role: FamilyRole }

/// A birthday change: `birthday` is sent as null to clear it.
struct FamilyBirthdayInput: Encodable {
    let birthday: Day?

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(birthday, forKey: .birthday)
    }

    private enum CodingKeys: String, CodingKey { case birthday }
}

struct FamilyPersonInput: Encodable {
    let name: String
    let birthday: Day?
    var invite: FamilyRole?

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(birthday, forKey: .birthday)
        try c.encode(invite, forKey: .invite)
    }

    private enum CodingKeys: String, CodingKey { case name, birthday, invite }
}

struct FamilyHomeInput: Encodable {
    let address: String
    let lat: Double?
    let lng: Double?

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(address, forKey: .address)
        try c.encode(lat, forKey: .lat)
        try c.encode(lng, forKey: .lng)
    }

    private enum CodingKeys: String, CodingKey { case address, lat, lng }
}

// MARK: Pure helpers

enum FamilyBirthdays {
    /// Full years on `today` (server/lib/families/birthdays.ts `ageOn`).
    static func age(_ birthday: Day, on today: Day) -> Int {
        let years = today.year - birthday.year
        return (today.month, today.day) < (birthday.month, birthday.day) ? years - 1 : years
    }

    /// "3 May 2019 · 7 years" (`settings.birthdayAge`).
    static func text(_ birthday: Day, today: Day = .today) -> String {
        let date = birthday.formatted(.dateTime.day().month(.abbreviated).year())
        let age = age(birthday, on: today)
        return String(AttributedString(localized: "\(date) · ^[\(age) year](inflect: true)").characters)
    }
}

extension FamilyRole {
    var title: LocalizedStringKey {
        switch self {
        case .editor: "Editor"
        case .viewer: "Viewer"
        }
    }

    var hint: LocalizedStringKey {
        switch self {
        case .editor: "can change everything and add people"
        case .viewer: "can only look"
        }
    }
}

/// The family's export file (server/lib/calendar/export-file.ts).
enum FamilyExportFile {
    static let formats = ["family-planner", "vacation-planner"]

    /// "Krug 2026-10-30.json" (`exportFileName`).
    static func fileName(familyName: String, today: Day) -> String {
        let forbidden = CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)
        var out = ""
        var inRun = false
        for scalar in familyName.unicodeScalars {
            if forbidden.contains(scalar) {
                if !inRun { out += "-" }
                inRun = true
            } else {
                out.unicodeScalars.append(scalar)
                inRun = false
            }
        }
        let name = out.trimmingCharacters(in: .whitespaces)
        return "\(name.isEmpty ? "family" : name) \(today).json"
    }

    /// True for JSON with an export file's `format` (`parseExportFile`); the server checks the rest.
    static func isExportFile(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = object["format"] as? String else { return false }
        return formats.contains(format)
    }

    /// The server's answer, indented like the web's download.
    static func pretty(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return data }
        return pretty + Data("\n".utf8)
    }
}

/// The export as a document for `.fileExporter`.
nonisolated struct FamilyExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
