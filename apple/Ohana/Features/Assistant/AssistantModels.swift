import Foundation

// The assistant's API types (web/components/assistant/api.ts and chat-store.ts, server side
// web/lib/assistant/{routes.ts,chat-routes.ts,chats.ts}).

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
    /// plan | shopping | appointments (and later modules' kinds)
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

/// What the chat shows: messages, tool activity, changes (with undo), questions. Decoded by
/// `kind`; a kind this app doesn't know yet becomes `.unknown` (and isn't shown).
enum AssistantItem: Decodable, Equatable {
    case user(text: String, attachments: [AssistantAttachmentRef])
    case assistant(text: String)
    case tool(AssistantToolCall)
    case change(AssistantChange)
    case question(AssistantQuestion)
    /// From here on, the model gets the earlier part of the chat as a summary.
    case compacted
    case error(text: String)
    case unknown(kind: String)

    private enum Keys: String, CodingKey {
        case kind, text, attachments, id, name, args, status, summary, result, interrupted
        case change, undo, undone, question, options, multiple, answer, skipped
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
/// user is (the page, the year, their language and day).
struct AssistantChatInput: Encodable {
    var text: String?
    var attachments: [AssistantOutgoingAttachment]?
    var page: String
    var year: Int
    var lang: String
    var today: String
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
