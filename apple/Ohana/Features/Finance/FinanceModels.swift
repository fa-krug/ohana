import Foundation

// The finance API's JSON (server/lib/finance/finance.ts: publicCategory, publicAccount,
// publicTransaction, overviewData, financeSummary, the routes' answers). Amounts are integer
// cents, negative for money going out; days are "YYYY-MM-DD".

enum FinanceCategoryKind: String, Codable, CaseIterable, Hashable, Identifiable {
    case expense, income, both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: String(localized: "Expense")
        case .income: String(localized: "Income")
        case .both: String(localized: "Both")
        }
    }
}

/// A category (publicCategory). A subcategory has the kind of its top-level category.
struct FinanceCategory: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String
    var icon: String
    var kind: FinanceCategoryKind
    /// Among its siblings.
    var position: Int
    /// Nil for a top-level category.
    var parentId: String?

    /// "🛒 Groceries".
    var label: String { icon.isEmpty ? name : "\(icon) \(name)" }
}

/// A bank account with its balance: the opening balance plus all its transactions (publicAccount).
struct FinanceAccount: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var color: String
    var icon: String
    var openingCents: Int
    var position: Int
    var balanceCents: Int

    var label: String { icon.isEmpty ? name : "\(icon) \(name)" }
}

/// A booking that has parts: how many, and what it still counts itself.
struct FinanceSplitInfo: Codable, Hashable {
    var parts: Int
    var remainderCents: Int
}

/// A transaction (publicTransaction with links).
struct FinanceTransaction: Codable, Hashable, Identifiable {
    var id: String
    var date: String
    var amountCents: Int
    var payee: String
    var description: String
    var categoryId: String?
    var accountId: String?
    /// Set on the legs of a transfer (≥ 2 transactions that count once, as their sum).
    var transferId: String?
    /// Set on a part of a split booking: the booking's id.
    var splitOf: String?
    /// Set on a booking that has parts.
    var split: FinanceSplitInfo?
    var note: String
    var imported: Bool

    var day: Day? { Day(date) }
    /// The payee, else the description, else a dash.
    var title: String { !payee.isEmpty ? payee : (!description.isEmpty ? description : "—") }
}

/// An amount per month from lowCents to highCents (the same twice for a single value).
struct FinanceCentsRange: Codable, Hashable {
    var lowCents: Int
    var highCents: Int
}

struct FinanceBenchmarkCategory: Codable, Hashable {
    var categoryId: String
    var lowCents: Int
    var highCents: Int

    var range: FinanceCentsRange { FinanceCentsRange(lowCents: lowCents, highCents: highCents) }
}

/// A statistic average to compare with: ranges per month.
struct FinanceBenchmark: Codable, Hashable {
    var label: String
    var income: FinanceCentsRange?
    var expense: FinanceCentsRange?
    var categories: [FinanceBenchmarkCategory]
}

/// GET /finance (overviewData), also the answer of PATCH /finance/settings and DELETE /finance.
struct FinanceOverview: Codable, Hashable {
    var currency: String
    /// Saved bank formats; kept as JSON so ones this app can't read survive a save.
    var csvMappings: [JSONValue]
    var benchmark: FinanceBenchmark?
    var categories: [FinanceCategory]
    var accounts: [FinanceAccount]

    /// The saved mappings this app can read, newest first.
    var mappings: [FinanceCSVMapping] {
        csvMappings.compactMap { FinanceCSVMapping(json: $0) }
    }
}

/// GET /finance/transactions
struct FinanceTransactionList: Codable, Hashable {
    var transactions: [FinanceTransaction]
    var total: Int
    var incomeCents: Int
    var expenseCents: Int
}

struct FinanceSummaryMonth: Codable, Hashable, Identifiable {
    /// "YYYY-MM"
    var month: String
    var incomeCents: Int
    var expenseCents: Int

    var id: String { month }
}

struct FinanceSummaryCategory: Codable, Hashable {
    var categoryId: String?
    var incomeCents: Int
    var expenseCents: Int
    var count: Int
}

/// GET /finance/summary (financeSummary).
struct FinanceSummary: Codable, Hashable {
    var currency: String
    var incomeCents: Int
    var expenseCents: Int
    var count: Int
    var months: [FinanceSummaryMonth]
    var categories: [FinanceSummaryCategory]
}

/// POST /finance/transactions and POST /finance/transfers/auto: `inverse` undoes it.
struct FinanceChangeResult: Codable {
    var changed: Int
    var added: [String]
    var inverse: [JSONValue]
    /// transfers/auto only.
    var linked: Int?
    var splits: Int?
}

/// POST /finance/import
struct FinanceImportResult: Codable, Hashable {
    var added: Int
    /// Indexes of the rows that were imported before.
    var duplicates: [Int]
    var ids: [String]
    var transfers: Int?
    var splits: Int?
}

/// Two transactions that look like money moved between two of the family's accounts.
struct FinanceTransferPair: Codable, Hashable, Identifiable {
    var out: FinanceTransaction
    var incoming: FinanceTransaction

    var id: String { out.id + "|" + incoming.id }

    enum CodingKeys: String, CodingKey {
        case out
        case incoming = "in"
    }
}

/// GET /finance/transfers/suggestions
struct FinanceTransferSuggestions: Codable {
    var pairs: [FinanceTransferPair]
}

/// GET /finance/accounts?at=
struct FinanceAccountsAt: Codable {
    var at: String?
    var accounts: [FinanceAccount]
}

/// POST /ai/categorize (server/lib/assistant/routes.ts categorize).
struct FinanceCategorizeResult: Codable {
    var changed: Int
    var matched: Int
    var considered: Int
    var remaining: Int
    var ai: Bool
    var inverse: [JSONValue]
    /// Which category each sorted transaction got.
    var assignments: [Assignment]?

    struct Assignment: Codable {
        var id: String
        var categoryId: String
    }
}

/// GET /ai/settings, the one field the finances need: whether the assistant is set up.
struct FinanceAIStatus: Codable {
    var configured: Bool
}

/// Building JSON bodies: amounts go as whole numbers.
enum FinanceJSON {
    static func int(_ value: Int) -> JSONValue { .number(Double(value)) }
    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func ids(_ ids: [String]) -> JSONValue { .array(ids.map(JSONValue.string)) }

    static func encode(_ value: some Encodable) -> JSONValue {
        guard let data = try? APIClient.encoder.encode(value),
              let json = try? APIClient.decoder.decode(JSONValue.self, from: data) else { return .null }
        return json
    }
}

/// An op for POST /finance/transactions (parseTxOp).
enum FinanceOp {
    /// The fields of a transaction as the add / update ops take them.
    struct Fields {
        var date: String
        var amountCents: Int
        var payee: String
        var description: String
        var categoryId: String?
        var accountId: String?
        var note: String

        var json: [String: JSONValue] {
            [
                "date": .string(date),
                "amountCents": FinanceJSON.int(amountCents),
                "payee": .string(payee),
                "description": .string(description),
                "categoryId": FinanceJSON.string(categoryId),
                "accountId": FinanceJSON.string(accountId),
                "note": .string(note),
            ]
        }
    }

    static func add(_ fields: Fields) -> JSONValue {
        .object(fields.json.merging(["action": .string("add")]) { a, _ in a })
    }

    static func update(_ id: String, _ fields: Fields) -> JSONValue {
        .object(fields.json.merging(["action": .string("update"), "id": .string(id)]) { a, _ in a })
    }

    static func setCategory(_ id: String, _ categoryId: String?) -> JSONValue {
        .object(["action": .string("update"), "id": .string(id), "categoryId": FinanceJSON.string(categoryId)])
    }

    static func delete(_ ids: [String]) -> JSONValue {
        .object(["action": .string("delete"), "ids": FinanceJSON.ids(ids)])
    }

    static func link(_ ids: [String]) -> JSONValue {
        .object(["action": .string("link"), "ids": FinanceJSON.ids(ids)])
    }

    static func unlink(_ id: String) -> JSONValue {
        .object(["action": .string("unlink"), "ids": FinanceJSON.ids([id])])
    }

    static func split(booking: String, parts: [String]) -> JSONValue {
        .object(["action": .string("split"), "id": .string(booking), "ids": FinanceJSON.ids(parts)])
    }

    static func unsplit(_ id: String) -> JSONValue {
        .object(["action": .string("unsplit"), "ids": FinanceJSON.ids([id])])
    }
}

/// Day arithmetic on "YYYY-MM-DD" strings (lib/calendar/dates.ts, without time zones).
enum FinanceDates {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    static func date(_ day: Day) -> Date {
        utc.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
    }

    /// Days from `a` to `b` (positive when b is later).
    static func days(from a: Day, to b: Day) -> Int {
        utc.dateComponents([.day], from: date(a), to: date(b)).day ?? 0
    }

    static func daysIn(year: Int, month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// "2026-05" of a day string.
    static func month(of date: String) -> String { String(date.prefix(7)) }

    /// The first day of a "YYYY-MM" month, at noon local time (for formatting).
    static func monthDate(_ month: String) -> Date {
        Day(month + "-01")?.date ?? Date()
    }
}
