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
    /// Its connection to the bank, when it syncs instead of importing CSV files (absent from
    /// older servers and the demo).
    var bank: FinanceBankLink? = nil

    var label: String { icon.isEmpty ? name : "\(icon) \(name)" }
}

/// An account's bank connection (publicAccount `bank`); the credentials stay on the server.
struct FinanceBankLink: Codable, Hashable {
    var provider: String
    /// Which account at the bank (or `card`); nil: the only one there.
    var iban: String?
    /// A credit card instead: the last 4 digits of its number (absent from older servers).
    var card: String? = nil
    var lastSyncAt: String?
    /// The account's booked balance at the bank as of the last sync that brought one (absent
    /// from older servers; nil for a card).
    var balanceCents: Int? = nil
    var balanceAt: String? = nil

    /// The provider's name, else its id (one this app doesn't know yet).
    var providerName: String { FinanceBankProvider(rawValue: provider)?.title ?? provider }
    var lastSync: Date? { lastSyncAt.flatMap(Date.server) }
}

/// The banks an account can sync with, and the credentials each needs (PUT …/bank).
enum FinanceBankProvider: String, CaseIterable, Hashable, Identifiable {
    case comdirect

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comdirect: "comdirect"
        }
    }

    /// One credential of the link: its key in the body, what the editor calls it, whether it's
    /// typed hidden.
    struct Field: Hashable, Identifiable {
        var key: String
        var title: String
        var secure = false

        var id: String { key }
    }

    /// All required for a new link; a blank one keeps the stored value on an existing link.
    var fields: [Field] {
        switch self {
        case .comdirect:
            [Field(key: "clientId", title: String(localized: "Client ID")),
             Field(key: "clientSecret", title: String(localized: "Client secret"), secure: true),
             Field(key: "username", title: String(localized: "Login number")),
             Field(key: "pin", title: String(localized: "PIN"), secure: true)]
        }
    }

    /// Where the credentials come from.
    var help: String {
        switch self {
        case .comdirect:
            String(localized: "The client ID and secret appear once you turn on API access in comdirect’s online banking. Each sync is confirmed in the comdirect app or with a TAN.")
        }
    }

    /// The body of PUT /finance/accounts/{id}/bank: blank credentials left out (an existing
    /// link keeps them), `iban` and `card` always both there, the one not used null.
    func linkBody(credentials: [String: String], target: FinanceBankTarget) -> JSONValue {
        var body: [String: JSONValue] = ["provider": .string(rawValue), "iban": .null, "card": .null]
        switch target {
        case .any: break
        case .iban(let iban): body["iban"] = .string(iban)
        case .card(let digits): body["card"] = .string(digits)
        }
        for field in fields {
            let value = (credentials[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { body[field.key] = .string(value) }
        }
        return .object(body)
    }

    /// Whether a link can be saved: a new one (or another provider's) needs every credential.
    func isComplete(credentials: [String: String], replacing link: FinanceBankLink?) -> Bool {
        if link?.provider == rawValue { return true }
        return fields.allSatisfy { !(credentials[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

/// Which account at the bank a link syncs, from the editor's one text field: an IBAN, or a
/// credit card by the last 4 digits of its number.
enum FinanceBankTarget: Hashable {
    /// Blank: the only account there.
    case any
    /// No spaces, capitals.
    case iban(String)
    /// The card number's last 4 digits.
    case card(String)

    /// Spaces dropped; two letters (not a masked "XXXX …") start an IBAN, else at least 4 digits
    /// are a card number or its end ("4871 78XX XXXX 0175", "•••• 0175"); nil: neither.
    init?(parsing text: String) {
        let compact = text.filter { !$0.isWhitespace }
        let start = Array(compact.prefix(3))
        func letter(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        if compact.isEmpty {
            self = .any
        } else if start.count >= 2, letter(start[0]), letter(start[1]), start.count == 2 || !letter(start[2]) {
            self = .iban(compact.uppercased())
        } else {
            let digits = compact.filter { ("0"..."9").contains($0) }
            guard digits.count >= 4 else { return nil }
            self = .card(String(digits.suffix(4)))
        }
    }

    /// What a link syncs now.
    init(_ link: FinanceBankLink?) {
        if let card = link?.card, !card.isEmpty {
            self = .card(card)
        } else if let iban = link?.iban?.filter({ !$0.isWhitespace }).uppercased(), !iban.isEmpty {
            self = .iban(iban)
        } else {
            self = .any
        }
    }

    /// The editor's text for it, which parses back to the same target.
    var text: String {
        switch self {
        case .any: ""
        case .iban(let iban): iban
        case .card(let digits): "•••• \(digits)"
        }
    }
}

/// A bank sync (GET /finance/accounts/{id}/bank/sync): the server's worker logs in, waits for
/// the TAN, loads and imports the transactions; the app polls it while it runs.
struct FinanceBankSync: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case waiting, running, tan, done, failed
    }

    /// What a running sync does (`step`).
    enum Step: String, Hashable {
        case login, tan, fetch
        case importing = "import"
    }

    /// How the bank wants the login confirmed.
    struct Challenge: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            /// Approve it in the bank's app; nothing to type.
            case push
            /// Scan the graphic with the bank's app, then type the TAN.
            case photo
            /// Type the TAN sent by text message.
            case sms
            /// A kind this app doesn't know yet (a newer server): type the TAN.
            case other

            init(from decoder: Decoder) throws {
                self = Kind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
            }
        }

        var type: Kind
        /// The photoTAN graphic, a base64 PNG.
        var image: String?
        /// E.g. the masked phone number.
        var hint: String?

        var imageData: Data? { image.flatMap { Data(base64Encoded: $0) } }
        var needsTan: Bool { type != .push }
    }

    struct Result: Codable, Hashable {
        var added: Int
        var duplicates: Int
        var transfers: Int
        var splits: Int
        /// The added transactions.
        var ids: [String]
        /// A full sync's: the account's transactions that now stand for a bank row (same day and
        /// amount; kept as they were).
        var adopted: Int?
        /// A full sync's: the account's transactions of the days fetched the bank doesn't list
        /// (left as they are; perhaps a CSV file's duplicates).
        var unmatched: Int?
        /// A full sync with the bank's balance: the opening balance it set, so that the account's
        /// balance is the bank's from the bank's first booking day on.
        var openingCents: Change?

        struct Change: Codable, Hashable {
            var from: Int
            var to: Int
        }
    }

    var id: String
    var accountId: String
    var status: Status
    /// Kept as text: a step this app doesn't know shows as working.
    var step: String?
    var tan: Challenge?
    var result: Result?
    var error: String?
    var createdAt: String?
    var updatedAt: String?
    /// Imports the bank's whole history (nil: an older server's, never one).
    var full: Bool?

    var stage: Step? { step.flatMap(Step.init) }
    /// Waiting, running or waiting for the TAN: it's polled.
    var isRunning: Bool { status != .done && status != .failed }
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
    /// Where it came from: "manual", "csv" or "bank" (nil from an older server).
    var source: String?

    var day: Day? { Day(date) }
    /// Where it came from; an older server only says whether it was imported.
    var origin: FinanceSource? {
        source.flatMap(FinanceSource.init(rawValue:)) ?? (imported ? .imported : nil)
    }
    /// The payee, else the description, else a dash.
    var title: String { !payee.isEmpty ? payee : (!description.isEmpty ? description : "—") }
}

/// Where a transaction came from (its `source`).
enum FinanceSource: String, Hashable {
    case manual, csv, bank
    /// An older server's imported row: a CSV file or a bank sync.
    case imported

    /// The mark in the lists; none for a typed one.
    var icon: String? {
        switch self {
        case .manual: nil
        case .csv: "doc.text"
        case .bank: "building.columns"
        case .imported: "square.and.arrow.down"
        }
    }

    var title: String {
        switch self {
        case .manual: String(localized: "Entered in Ohana")
        case .csv: String(localized: "Imported from a CSV file")
        case .bank: String(localized: "Synced with the bank")
        case .imported: String(localized: "Imported from a bank statement")
        }
    }
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
