import Foundation

extension DemoServer {
    /// The demo's search across the modules (`/search?q=`), over the other demo files the way
    /// server/lib/families/search.ts searches: every word in the item (case and accents
    /// ignored), title matches first, then the ones nearest to today; eight per kind.
    static func search(_ request: Request) -> JSONValue? {
        guard request.familyPath == "/search" else { return nil }
        let query = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let currency = request.json("finance")?["currency"]?.stringValue ?? "EUR"
        guard !terms.isEmpty else {
            return .object(["query": .string(query), "currency": .string(currency), "results": .array([]), "more": .object([:])])
        }
        let phrase = terms.joined(separator: " ")
        var results: [JSONValue] = []
        var more: [String: JSONValue] = [:]
        for (kind, items) in candidates(request) {
            let ranked = items.compactMap { item -> (item: DemoSearchItem, score: Int)? in
                let score = item.score(terms, phrase)
                return score > 0 ? (item, score) : nil
            }
            .sorted {
                $0.score != $1.score ? $0.score > $1.score
                    : distance($0.item.day, request.today) < distance($1.item.day, request.today)
            }
            results += ranked.prefix(8).map { $0.item.json(kind) }
            if ranked.count > 8 { more[kind] = .number(Double(ranked.count - 8)) }
        }
        return .object(["query": .string(query), "currency": .string(currency), "results": .array(results), "more": .object(more)])
    }

    /// The demo's items by kind, in the server's order.
    private static func candidates(_ request: Request) -> [(String, [DemoSearchItem])] {
        let s = { (value: JSONValue?, key: String) in value?[key]?.stringValue ?? "" }
        let recipes = (request.json("meals-recipes")?["items"]?.arrayValue ?? []).map {
            DemoSearchItem(id: s($0, "id"), title: s($0, "title"), detail: firstLine(s($0, "description")),
                           text: [s($0, "description")])
        }
        let calendar = request.json("calendar")
        let events = (calendar?["events"]?.arrayValue ?? []).map {
            DemoSearchItem(id: s($0, "id"), title: s($0, "title"), detail: joined(s($0, "location"), s($0, "person")),
                           text: [s($0, "note")], day: s($0, "date"), extra: ["time": $0["start"] ?? .null])
        }
        let notes = (calendar?["notes"]?.objectValue ?? [:]).compactMap { day, note -> DemoSearchItem? in
            let comment = s(note, "comment")
            guard !comment.isEmpty else { return nil }
            return DemoSearchItem(id: day, title: joined(s(note, "icon"), firstLine(comment)), detail: "", text: [comment], day: day)
        }
        let categories = Dictionary((request.json("finance")?["categories"]?.arrayValue ?? []).map { (s($0, "id"), s($0, "name")) },
                                    uniquingKeysWith: { a, _ in a })
        let transactions = (request.json("finance-transactions")?["transactions"]?.arrayValue ?? []).map { t in
            let payee = s(t, "payee")
            return DemoSearchItem(id: s(t, "id"), title: payee.isEmpty ? firstLine(s(t, "description")) : payee,
                                  detail: joined(payee.isEmpty ? "" : firstLine(s(t, "description")), categories[s(t, "categoryId")] ?? ""),
                                  text: [s(t, "description"), s(t, "note")], day: s(t, "date"),
                                  extra: ["amountCents": t["amountCents"] ?? .number(0)])
        }
        let searches = (request.json("appointments")?["searches"]?.arrayValue ?? []).map {
            let speciality = s($0, "specialityLabel").isEmpty ? s($0, "jamedaSpecialityLabel") : s($0, "specialityLabel")
            return DemoSearchItem(id: s($0, "id"), title: s($0, "name"), detail: joined(speciality, s($0, "locationLabel")))
        }
        let household = request.json("household")
        let members = (household?["members"]?.arrayValue ?? []).map {
            let name = s($0, "name")
            return DemoSearchItem(id: s($0, "userId"), title: name.isEmpty ? s($0, "email") : name,
                                  detail: name.isEmpty ? "" : s($0, "email"), extra: ["account": .bool(true)])
        }
        let people = (household?["people"]?.arrayValue ?? []).map {
            DemoSearchItem(id: s($0, "id"), title: s($0, "name"), detail: "", extra: ["account": .bool(false)])
        }
        let chats = (request.json("ai-chats")?["chats"]?.arrayValue ?? []).map {
            DemoSearchItem(id: s($0, "id"), title: s($0, "title"), detail: "", day: String(s($0, "updatedAt").prefix(10)))
        }
        return [("recipe", recipes), ("event", events), ("note", notes), ("transaction", transactions),
                ("search", searches), ("person", members + people), ("chat", chats)]
    }

    fileprivate static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func distance(_ day: String?, _ today: Day) -> Int {
        guard let day = day.flatMap(Day.init) else { return .max }
        return abs(Day.calendar.dateComponents([.day], from: today.date, to: day.date).day ?? 0)
    }

    private static func joined(_ parts: String...) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func firstLine(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first ?? "")
    }
}

/// One thing the demo's search looks through.
private struct DemoSearchItem {
    var id: String
    var title: String
    var detail: String
    var text: [String] = []
    var day: String?
    /// The kind's own fields (an event's time, an amount, a person's account).
    var extra: [String: JSONValue] = [:]

    /// 0: not every term is in it; title as the phrase 4, starting with it 3, holding every term 2, else 1.
    func score(_ terms: [String], _ phrase: String) -> Int {
        let t = DemoServer.fold(title)
        let all = DemoServer.fold(([title, detail] + text).joined(separator: "\n"))
        guard terms.allSatisfy({ all.contains($0) }) else { return 0 }
        if t == phrase { return 4 }
        if t.hasPrefix(phrase) { return 3 }
        return terms.allSatisfy { t.contains($0) } ? 2 : 1
    }

    func json(_ kind: String) -> JSONValue {
        var o: [String: JSONValue] = ["kind": .string(kind), "id": .string(id), "title": .string(title),
                                      "detail": .string(detail), "day": day.map { .string($0) } ?? .null]
        o.merge(extra) { _, new in new }
        return .object(o)
    }
}
