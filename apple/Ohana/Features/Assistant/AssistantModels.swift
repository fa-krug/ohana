import Foundation

// The assistant's API types (web/components/assistant/api.ts and chat-store.ts, server side
// server/lib/assistant/{routes.ts,chat-routes.ts,chats.ts}).

// MARK: Settings

/// GET/PUT /ai/settings. Editors get the whole setup (never the keys, only their last four
/// characters); viewers only whether it is set up.
struct AssistantSettings: Codable, Equatable {
    var configured: Bool
    var canEdit: Bool
    var baseUrl: String?
    var model: String
    var hasKey: Bool?
    var keyHint: String?
    var searchProvider: String?
    var hasSearchKey: Bool?
    var searchKeyHint: String?
    var allowWrites: Bool
    /// Tokens; 0: from the API's model list (or 128,000).
    var contextWindow: Int?
    /// The model for recipe photos; "" = none.
    var imageModel: String?
    var serverReady: Bool?
}

/// PUT /ai/settings: only the fields given change (`apiKey: ""` removes the key).
struct AssistantSettingsPatch: Encodable {
    var baseUrl: String?
    var apiKey: String?
    var model: String?
    var searchProvider: String?
    var searchKey: String?
    var allowWrites: Bool?
    var contextWindow: Int?
    var imageModel: String?
}

struct AssistantModelList: Decodable { let models: [String] }
struct AssistantTestResult: Decodable { let ok: Bool; let model: String; let reply: String }

// MARK: Chats

/// What a running turn does right now.
struct AssistantActivity: Codable, Equatable {
    /// thinking | writing | tool | compacting | retrying (and later kinds).
    var kind: String
    var attempt: Int?
    var max: Int?
}

/// How full the model's context is: the tokens the chat uses, and the most it takes.
struct AssistantUsage: Codable, Equatable {
    var used: Double
    var max: Double
}

/// A message written while the assistant answered: it goes next (attachments by name).
struct AssistantQueued: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var attachments: [AssistantAttachmentRef]?

    /// Still on its way to the server.
    var isLocal: Bool { id.hasPrefix("local-") }
}

/// An attachment as the chat shows it: images with their data URL (while the server keeps it).
struct AssistantAttachmentRef: Codable, Equatable, Hashable {
    /// image | file
    var kind: String
    var name: String
    var url: String?
}

/// A chat as the list shows it (`summaryOf` in chats.ts).
struct AssistantChatSummary: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    /// idle | running
    var status: String
    var activity: AssistantActivity?
    var usage: AssistantUsage?
    /// The page the chat belongs to (null for an old chat).
    var page: String?
    var queued: [AssistantQueued]?
    var updatedAt: String

    var isRunning: Bool { status == "running" }

    var updatedDate: Date? { AssistantDates.parse(updatedAt) }
}

struct AssistantChatList: Decodable { let chats: [AssistantChatSummary] }

/// GET /ai/chats/{id}: the chat, its items (by position) and their revision.
struct AssistantChatState: Decodable {
    let chat: AssistantChatSummary
    let rev: Int
    let items: [AssistantItem]
}

/// POST /ai/chats/{id}/queue (202) and /unqueue.
struct AssistantQueueResult: Decodable {
    let chat: AssistantChatSummary
    let id: String?
}

/// A request against /families/{id} that undoes (part of) a change the assistant made.
struct AssistantUndoStep: Codable, Equatable {
    /// POST | PATCH | DELETE
    var method: String
    /// Relative to the family, e.g. `/entries` or `/types/x?year=2027`.
    var path: String
    var body: JSONValue?
}

// MARK: Items

struct AssistantToolCall: Equatable {
    var id: String
    var name: String
    var args: [String: JSONValue]
    /// running | ok | error
    var status: String
    var summary: String?
    /// The start of what the model got back.
    var result: String?
    /// It was running when its turn broke off.
    var interrupted: Bool
}

struct AssistantChange: Equatable {
    var id: String
    /// entries | notes | types | events | categories | transactions | benchmark | recipes |
    /// plan | appointments (and later modules' kinds)
    var change: String
    var summary: String
    var undo: [AssistantUndoStep]
    var undone: Bool
}

struct AssistantQuestion: Equatable {
    var id: String
    var question: String
    var options: [String]
    var multiple: Bool
    /// What the user picked and wrote.
    var answer: Answer?
    /// The user wrote a new message instead.
    var skipped: Bool

    struct Answer: Codable, Equatable {
        var selected: [String]
        var text: String?
    }
}

/// A change of the user's Reminders the assistant suggests (`kind: "reminders"`, server
/// lib/assistant/tools/reminders.ts): nothing changes until the user applies it on their device,
/// which answers with one result per op.
struct AssistantRemindersEdit: Equatable {
    var id: String
    /// What it does, e.g. "Add 3 reminders to Groceries".
    var summary: String
    var ops: [AssistantReminderOp]
    /// Applied (with each op's result) or declined.
    var answer: Answer?
    /// The user wrote a new message instead.
    var skipped: Bool

    /// `{applied: true, results}` or `{applied: false}`.
    struct Answer: Codable, Equatable {
        var applied: Bool
        var results: [AssistantReminderResult]?

        /// How many of the ops failed (ops the user left out don't count).
        var failures: Int { (results ?? []).filter(\.failed).count }
    }
}

/// One change of a Reminders edit, as the server resolved it: `list` is always a list's id
/// (with its title); ops on an existing reminder name it (`id`, `itemTitle`).
/// add: `list`, `title`, `notes`?, `due`?; update: `id`, `list` (the reminder's list, or the one it
/// moves to), `title`?, `notes`? ("" clears them), `due`? (null clears it); complete | uncomplete |
/// delete: `id`. Decoded leniently: an op this app doesn't know keeps its `op` (and fails when
/// applied).
struct AssistantReminderOp: Decodable, Equatable {
    /// add | update | complete | uncomplete | delete
    var op: String
    var id: String?
    var itemTitle: String?
    var list: String
    var listTitle: String
    var title: String?
    var notes: String?
    var due: DueChange

    /// What an op does to the due date.
    enum DueChange: Equatable {
        /// Not part of the op.
        case keep
        /// `due: null` (update): the reminder has no due date any more.
        case clear
        case set(ReminderDue)
    }

    init(op: String, id: String? = nil, itemTitle: String? = nil, list: String, listTitle: String,
         title: String? = nil, notes: String? = nil, due: DueChange = .keep) {
        self.op = op
        self.id = id
        self.itemTitle = itemTitle
        self.list = list
        self.listTitle = listTitle
        self.title = title
        self.notes = notes
        self.due = due
    }

    private enum Keys: String, CodingKey { case op, id, itemTitle, list, listTitle, title, notes, due }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self.init(op: "", list: "", listTitle: "")
            return
        }
        func opt(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        let due: DueChange
        if !c.contains(.due) {
            due = .keep
        } else if (try? c.decodeNil(forKey: .due)) == true {
            due = .clear
        } else if let text = opt(.due), let value = ReminderDue(text) {
            due = .set(value)
        } else {
            due = .keep
        }
        self.init(op: opt(.op) ?? "", id: opt(.id), itemTitle: opt(.itemTitle), list: opt(.list) ?? "",
                  listTitle: opt(.listTitle) ?? "", title: opt(.title), notes: opt(.notes), due: due)
    }

    /// The reminder it is about: the new one's title for add, else the reminder's.
    var subject: String { (op == "add" ? title : itemTitle) ?? "" }
}

/// How one op went on the device: `{ok: true, id?}`, `{ok: false, error}`, or `{ok: false,
/// declined: true}` for a suggestion the user left out (a calendar edit's and suggestions' too).
struct AssistantReminderResult: Codable, Equatable {
    var ok: Bool
    /// The reminder (the new one for add).
    var id: String?
    var error: String?
    /// The user left it out (suggestions): not a failure.
    var declined: Bool?

    static func done(_ id: String?) -> Self { .init(ok: true, id: id, error: nil) }
    static func failed(_ error: String) -> Self { .init(ok: false, id: nil, error: error) }
    static let declined = Self(ok: false, id: nil, error: nil, declined: true)

    var isDeclined: Bool { !ok && declined == true }
    /// It was tried and didn't go through.
    var failed: Bool { !ok && declined != true }
}

/// A change of the device's calendars the assistant suggests (`kind: "calendar"`, server
/// lib/assistant/tools/apple-calendar.ts): like a Reminders edit, nothing changes until the user
/// applies it on their device, which answers with one result per op.
struct AssistantCalendarEdit: Equatable {
    var id: String
    /// What it does, e.g. "Add “Dentist” to Family".
    var summary: String
    var ops: [AssistantCalendarOp]
    /// Applied (with each op's result) or declined.
    var answer: Answer?
    /// The user wrote a new message instead.
    var skipped: Bool

    typealias Answer = AssistantRemindersEdit.Answer
}

/// One change of a calendar edit, as the server resolved it: `calendar` is always a calendar's
/// id (with its title); ops on an existing event name it (`id`, `eventTitle`) and say when it is
/// now (`eventStart`, `eventEnd`, `eventAllDay`). Times are "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD"
/// all day (`end` then the last day).
/// add: `calendar`, `title`, `start`, `end`?, `allDay`?, `location`?, `notes`?, `rrule`?; update:
/// `id`, `span`? (this | future, for an occurrence), `calendar` (the event's, or the one it moves
/// to), `title`?, `start`?, `end`?, `allDay`?, `location`?, `notes`? ("" clears them); delete:
/// `id`, `span`?. Decoded leniently: an op this app doesn't know keeps its `op` (and fails when
/// applied).
struct AssistantCalendarOp: Decodable, Equatable {
    /// add | update | delete
    var op: String
    var id: String?
    var span: String?
    var eventTitle: String?
    var eventStart: String?
    var eventEnd: String?
    var eventAllDay: Bool?
    var calendar: String
    var calendarTitle: String
    var title: String?
    var start: String?
    var end: String?
    var allDay: Bool?
    var location: String?
    var notes: String?
    var rrule: String?

    init(op: String, id: String? = nil, span: String? = nil, eventTitle: String? = nil, eventStart: String? = nil,
         eventEnd: String? = nil, eventAllDay: Bool? = nil, calendar: String, calendarTitle: String,
         title: String? = nil, start: String? = nil, end: String? = nil, allDay: Bool? = nil, location: String? = nil,
         notes: String? = nil, rrule: String? = nil) {
        self.op = op
        self.id = id
        self.span = span
        self.eventTitle = eventTitle
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.eventAllDay = eventAllDay
        self.calendar = calendar
        self.calendarTitle = calendarTitle
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.rrule = rrule
    }

    private enum Keys: String, CodingKey {
        case op, id, span, eventTitle, eventStart, eventEnd, eventAllDay, calendar, calendarTitle, title, start, end
        case allDay, location, notes, rrule
    }

    init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self.init(op: "", calendar: "", calendarTitle: "")
            return
        }
        func opt(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        func flag(_ key: Keys) -> Bool? { try? c.decodeIfPresent(Bool.self, forKey: key) }
        let op = opt(.op) ?? ""
        // A delete has nothing to change: its times, if any, are the event's.
        let deletes = op == "delete"
        self.init(
            op: op, id: opt(.id), span: opt(.span), eventTitle: opt(.eventTitle),
            eventStart: opt(.eventStart) ?? (deletes ? opt(.start) : nil),
            eventEnd: opt(.eventEnd) ?? (deletes ? opt(.end) : nil),
            eventAllDay: flag(.eventAllDay) ?? (deletes ? flag(.allDay) : nil),
            calendar: opt(.calendar) ?? "", calendarTitle: opt(.calendarTitle) ?? "", title: opt(.title),
            start: deletes ? nil : opt(.start), end: deletes ? nil : opt(.end), allDay: deletes ? nil : flag(.allDay),
            location: opt(.location), notes: opt(.notes), rrule: opt(.rrule)
        )
    }

    /// The event it is about: the new one's title for add, else the event's.
    var subject: String { (op == "add" ? title : eventTitle) ?? "" }

    /// The day the event shows on now (where an occurrence moved away from its own day is found).
    var near: Day? { eventStart.flatMap { Day($0) } }
}

/// What the chat shows: messages, tool activity, changes (with undo), questions, changes of the
/// user's Reminders and calendars to apply, suggestions to add. Decoded by `kind`; a kind this app doesn't know yet becomes
/// `.unknown` (and isn't shown).
enum AssistantItem: Decodable, Equatable {
    case user(text: String, attachments: [AssistantAttachmentRef])
    case assistant(text: String)
    case tool(AssistantToolCall)
    case change(AssistantChange)
    case question(AssistantQuestion)
    /// A change of the user's Reminders (edit_reminders) that waits for them to apply it here.
    case reminders(AssistantRemindersEdit)
    /// A change of the device's calendars (edit_apple_calendar) that waits for them to apply it here.
    case calendar(AssistantCalendarEdit)
    /// Events, tasks and deadlines the assistant found (suggest_items, e.g. in a scanned letter)
    /// that wait for the user to pick which to add.
    case suggestions(AssistantSuggestions)
    /// From here on, the model gets the earlier part of the chat as a summary.
    case compacted
    case error(text: String)
    case unknown(kind: String)

    private enum Keys: String, CodingKey {
        case kind, text, attachments, id, name, args, status, summary, result, interrupted
        case change, undo, undone, question, options, multiple, answer, skipped, ops, source
    }

    init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self = .unknown(kind: "")
            return
        }
        guard let c = try? decoder.container(keyedBy: Keys.self) else {
            self = .unknown(kind: "")
            return
        }
        let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
        func str(_ key: Keys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        func opt(_ key: Keys) -> String? { try? c.decodeIfPresent(String.self, forKey: key) }
        func flag(_ key: Keys) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? false }
        switch kind {
        case "user":
            let attachments = try? c.decodeIfPresent([AssistantAttachmentRef].self, forKey: .attachments)
            self = .user(text: str(.text), attachments: attachments ?? [])
        case "assistant":
            self = .assistant(text: str(.text))
        case "tool":
            let args = (try? c.decodeIfPresent(JSONValue.self, forKey: .args))?.objectValue ?? [:]
            self = .tool(AssistantToolCall(
                id: str(.id), name: str(.name), args: args, status: opt(.status) ?? "ok",
                summary: opt(.summary), result: opt(.result), interrupted: flag(.interrupted)
            ))
        case "change":
            let undo = try? c.decodeIfPresent([AssistantUndoStep].self, forKey: .undo)
            self = .change(AssistantChange(
                id: str(.id), change: str(.change), summary: str(.summary), undo: undo ?? [], undone: flag(.undone)
            ))
        case "question":
            let options = try? c.decodeIfPresent([String].self, forKey: .options)
            let answer = try? c.decodeIfPresent(AssistantQuestion.Answer.self, forKey: .answer)
            self = .question(AssistantQuestion(
                id: str(.id), question: str(.question), options: options ?? [], multiple: flag(.multiple),
                answer: answer, skipped: flag(.skipped)
            ))
        case "reminders":
            let ops = try? c.decodeIfPresent([AssistantReminderOp].self, forKey: .ops)
            let answer = try? c.decodeIfPresent(AssistantRemindersEdit.Answer.self, forKey: .answer)
            self = .reminders(AssistantRemindersEdit(
                id: str(.id), summary: str(.summary), ops: ops ?? [], answer: answer, skipped: flag(.skipped)
            ))
        case "calendar":
            let ops = try? c.decodeIfPresent([AssistantCalendarOp].self, forKey: .ops)
            let answer = try? c.decodeIfPresent(AssistantCalendarEdit.Answer.self, forKey: .answer)
            self = .calendar(AssistantCalendarEdit(
                id: str(.id), summary: str(.summary), ops: ops ?? [], answer: answer, skipped: flag(.skipped)
            ))
        case "suggestions":
            let ops = try? c.decodeIfPresent([AssistantSuggestionOp].self, forKey: .ops)
            let answer = try? c.decodeIfPresent(AssistantSuggestions.Answer.self, forKey: .answer)
            let source = opt(.source)
            self = .suggestions(AssistantSuggestions(
                id: str(.id), summary: str(.summary), source: source?.isEmpty == false ? source : nil, ops: ops ?? [],
                answer: answer, skipped: flag(.skipped)
            ))
        case "compacted":
            self = .compacted
        case "error":
            self = .error(text: str(.text))
        default:
            self = .unknown(kind: kind)
        }
    }

    /// Shown in the chat: blank answers (left by a step that is tried again) and unknown kinds
    /// aren't.
    var isVisible: Bool {
        switch self {
        case let .assistant(text): !text.isEmpty
        case .unknown: false
        default: true
        }
    }

    var isUser: Bool { if case .user = self { true } else { false } }
}

// MARK: Streams

/// What a chat's stream (server-sent events) says: the chat, items that changed (by position;
/// `rev` once they are saved up to that revision), text as it is written, then the end (no
/// turn runs any more) or "reconnect" (ask again to go on following).
enum AssistantChatEvent: Equatable {
    case chat(AssistantChatSummary)
    case items(rev: Int?, items: [(seq: Int, item: AssistantItem)])
    case delta(seq: Int, text: String)
    case end(deleted: Bool)
    case reconnect

    static func == (a: Self, b: Self) -> Bool {
        switch (a, b) {
        case let (.chat(x), .chat(y)): x == y
        case let (.items(r1, i1), .items(r2, i2)):
            r1 == r2 && i1.count == i2.count && zip(i1, i2).allSatisfy { $0.seq == $1.seq && $0.item == $1.item }
        case let (.delta(s1, t1), .delta(s2, t2)): s1 == s2 && t1 == t2
        case let (.end(d1), .end(d2)): d1 == d2
        case (.reconnect, .reconnect): true
        default: false
        }
    }

    private struct ItemsData: Decodable {
        struct Entry: Decodable { let seq: Int; let item: AssistantItem }
        let rev: Int?
        let items: [Entry]
    }

    private struct DeltaData: Decodable { let seq: Int; let text: String }
    private struct EndData: Decodable { let deleted: Bool? }

    /// One event from its name and JSON data; nil for pings and events this app doesn't know.
    static func parse(event: String, data: String) throws -> AssistantChatEvent? {
        let bytes = Data(data.utf8)
        let decoder = JSONDecoder()
        switch event {
        case "chat":
            return .chat(try decoder.decode(AssistantChatSummary.self, from: bytes))
        case "items":
            let d = try decoder.decode(ItemsData.self, from: bytes)
            return .items(rev: d.rev, items: d.items.map { ($0.seq, $0.item) })
        case "delta":
            let d = try decoder.decode(DeltaData.self, from: bytes)
            return .delta(seq: d.seq, text: d.text)
        case "end":
            return .end(deleted: (try? decoder.decode(EndData.self, from: bytes))?.deleted ?? false)
        case "reconnect":
            return .reconnect
        default:
            return nil
        }
    }
}

/// Reads server-sent events line by line: `event: …` then `data: …` (blank lines may or may
/// not arrive; a data line completes an event either way).
struct AssistantSSEParser {
    private var event: String?

    /// The event a line completes, as (name, data); nil for anything else.
    mutating func feed(_ line: String) -> (event: String, data: String)? {
        if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:"), let name = event {
            event = nil
            var data = line.dropFirst(5)
            if data.first == " " { data = data.dropFirst() }
            return (name, String(data))
        } else if line.isEmpty {
            event = nil
        }
        return nil
    }
}

// MARK: Requests

/// A message for the assistant: the text, files as text, images as data URLs; and where the
/// user is (the page, the year, their language and day) and, with access, their Reminders and
/// the device's calendars.
struct AssistantChatInput: Encodable {
    var text: String?
    var attachments: [AssistantOutgoingAttachment]?
    var page: String
    var year: Int
    var lang: String
    var today: String
    /// Without it, the Reminders tools are off for the turn.
    var reminders: AssistantRemindersContext?
    /// Without it, the Apple Calendar tools are off for the turn.
    var appleCalendar: AssistantCalendarContext?
}

/// POST /ai/chats/{id}/answer
struct AssistantAnswerInput: Encodable {
    var id: String
    var selected: [String]
    var text: String?
    var page: String
    var year: Int
    var lang: String
    var today: String
    var reminders: AssistantRemindersContext?
    var appleCalendar: AssistantCalendarContext?
}

/// POST /ai/chats/{id}/reminders (and /suggestions): the waiting Reminders edit (or
/// suggestions) `id` applied (with one result per op, in order) or declined; `reminders` is the
/// snapshot after applying.
struct AssistantRemindersAnswerInput: Encodable {
    var id: String
    var applied: Bool
    var results: [AssistantReminderResult]?
    var page: String
    var year: Int
    var lang: String
    var today: String
    var reminders: AssistantRemindersContext?
    var appleCalendar: AssistantCalendarContext?
}

/// POST /ai/chats/{id}/calendar: the waiting calendar edit `id` applied (with one result per op,
/// in order) or declined; `appleCalendar` is the snapshot after applying.
struct AssistantCalendarAnswerInput: Encodable {
    var id: String
    var applied: Bool
    var results: [AssistantReminderResult]?
    var page: String
    var year: Int
    var lang: String
    var today: String
    var reminders: AssistantRemindersContext?
    var appleCalendar: AssistantCalendarContext?
}

nonisolated struct AssistantOutgoingAttachment: Encodable, Equatable {
    /// image | file
    var kind: String
    var name: String
    var url: String?
    var text: String?
}

enum AssistantDates {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        fractional.date(from: text) ?? plain.date(from: text)
    }

    /// "YYYY-MM-DD" of a date in the device's calendar.
    static func day(_ date: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
