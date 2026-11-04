import Foundation
import Testing
@testable import Ohana

/// Bank sync: the account's link and the sync as the server writes them, the link's body, and
/// what the finance page offers instead of the CSV import.
struct FinanceBankTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try APIClient.decoder.decode(T.self, from: Data(json.utf8))
    }

    private func account(_ id: String, linked: Bool) -> FinanceAccount {
        FinanceAccount(id: id, name: id.capitalized, color: "#3b82f6", icon: "", openingCents: 0, position: 0, balanceCents: 0,
                       bank: linked ? FinanceBankLink(provider: "comdirect", iban: nil, lastSyncAt: nil) : nil)
    }

    @Test func decodesAccountsWithAndWithoutALink() throws {
        let accounts = try decode([FinanceAccount].self, """
        [{"id":"cash","name":"Cash","color":"#22c55e","icon":"","openingCents":0,"position":1,"balanceCents":0},
         {"id":"savings","name":"Savings","color":"#22c55e","icon":"","openingCents":0,"position":2,"balanceCents":0,"bank":null},
         {"id":"giro","name":"Giro","color":"#3b82f6","icon":"","openingCents":0,"position":0,"balanceCents":100,
          "bank":{"provider":"comdirect","iban":"DE12500105170648489890","lastSyncAt":"2026-11-04T10:00:00.000Z"}},
         {"id":"other","name":"Other","color":"#3b82f6","icon":"","openingCents":0,"position":3,"balanceCents":0,
          "bank":{"provider":"newbank","iban":null,"lastSyncAt":null}},
         {"id":"visa","name":"Visa","color":"#3b82f6","icon":"","openingCents":0,"position":4,"balanceCents":0,
          "bank":{"provider":"comdirect","iban":null,"card":"0175","lastSyncAt":null}}]
        """)
        #expect(accounts[0].bank == nil)
        #expect(accounts[1].bank == nil)
        let link = try #require(accounts[2].bank)
        #expect(link.providerName == "comdirect")
        #expect(link.iban == "DE12500105170648489890")
        #expect(link.lastSync == Date(timeIntervalSince1970: 1_793_786_400))
        // A provider this app doesn't know shows as its id.
        #expect(accounts[3].bank?.providerName == "newbank")
        #expect(accounts[3].bank?.lastSync == nil)
        // Older servers send no card.
        #expect(link.card == nil)
        #expect(accounts[4].bank?.card == "0175")
    }

    @Test func decodesASyncWaitingForAPhotoTan() throws {
        let sync = try decode(FinanceBankSync.self, """
        {"id":"7d1c","accountId":"giro","status":"tan","step":"tan",
         "tan":{"type":"photo","image":"iVBORw0KGgo=","hint":null},"result":null,"error":null,
         "createdAt":"2026-11-04T10:00:00.000Z","updatedAt":"2026-11-04T10:00:01.000Z"}
        """)
        #expect(sync.status == .tan)
        #expect(sync.isRunning)
        #expect(sync.stage == .tan)
        #expect(sync.tan?.type == .photo)
        #expect(sync.tan?.needsTan == true)
        #expect(sync.tan?.imageData == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let push = try decode(FinanceBankSync.self, """
        {"id":"7d1c","accountId":"giro","status":"tan","step":"tan","tan":{"type":"push","image":null,"hint":null},
         "result":null,"error":null,"createdAt":"x","updatedAt":"x"}
        """)
        #expect(push.tan?.needsTan == false)
    }

    @Test func decodesTheEndOfASync() throws {
        let done = try decode(FinanceBankSync.self, """
        {"id":"7d1c","accountId":"giro","status":"done","step":null,"tan":null,
         "result":{"added":2,"duplicates":3,"transfers":1,"splits":0,"ids":["a","b"]},"error":null,
         "createdAt":"2026-11-04T10:00:00.000Z","updatedAt":"2026-11-04T10:00:09.000Z"}
        """)
        #expect(!done.isRunning)
        #expect(done.result?.ids == ["a", "b"])
        #expect(done.result?.duplicates == 3)
        #expect(done.result?.adopted == nil)
        #expect(done.full == nil)

        let full = try decode(FinanceBankSync.self, """
        {"id":"7d1d","accountId":"giro","status":"done","full":true,"step":null,"tan":null,
         "result":{"added":1,"duplicates":0,"transfers":0,"splits":0,"ids":["c"],"adopted":4,"unmatched":1},
         "error":null,"createdAt":"x","updatedAt":"x"}
        """)
        #expect(full.full == true)
        #expect(full.result?.adopted == 4)
        #expect(full.result?.unmatched == 1)
    }

    @Test func tellsWhereATransactionCameFrom() throws {
        func transaction(_ extra: String) throws -> FinanceTransaction {
            try decode(FinanceTransaction.self, """
            {"id":"t","date":"2026-10-01","amountCents":-100,"payee":"P","description":"","categoryId":null,
             "accountId":null,"transferId":null,"splitOf":null,"split":null,"note":""\(extra)}
            """)
        }
        #expect(try transaction(#","imported":true,"source":"bank""#).origin == .bank)
        #expect(try transaction(#","imported":true,"source":"csv""#).origin == .csv)
        #expect(try transaction(#","imported":false,"source":"manual""#).origin?.icon == nil)
        // An older server only says whether it was imported.
        #expect(try transaction(#","imported":true"#).origin == .imported)
        #expect(try transaction(#","imported":false"#).origin == nil)
        #expect(try transaction(#","imported":false,"source":"later""#).origin == nil)
    }

    @Test func filtersTheListByOrigin() {
        var filter = FinanceFilter()
        func source() -> String? { FinanceStore.listQuery(.current(), filter, limit: 50)["source"] ?? nil }
        #expect(source() == nil)
        filter.source = .notBank
        #expect(source() == "manual,csv")
        #expect(filter.activeCount == 1)
    }

    @Test func decodesAFailedSync() throws {
        let failed = try decode(FinanceBankSync.self, """
        {"id":"7d1c","accountId":"giro","status":"failed","step":"login","tan":null,"result":null,
         "error":"Cancelled","createdAt":"x","updatedAt":"x"}
        """)
        #expect(!failed.isRunning)
        #expect(failed.error == "Cancelled")
    }

    @Test func saysWhatARunningSyncDoes() throws {
        func sync(_ status: FinanceBankSync.Status, _ step: String?) -> FinanceBankSync {
            FinanceBankSync(id: "s", accountId: "giro", status: status, step: step)
        }
        let connecting = String(localized: "Connecting to \("comdirect")…")
        #expect(sync(.waiting, nil).progressText(bank: "comdirect") == connecting)
        #expect(sync(.running, nil).progressText(bank: "comdirect") == connecting)
        #expect(sync(.running, "login").progressText(bank: "comdirect") == connecting)
        #expect(sync(.running, "fetch").progressText(bank: "comdirect") == String(localized: "Loading transactions…"))
        #expect(sync(.running, "import").progressText(bank: "comdirect") == String(localized: "Importing…"))
        // A step this app doesn't know yet still reads as working.
        #expect(sync(.running, "verify").progressText(bank: "comdirect") == String(localized: "Syncing…"))
    }

    @Test func buildsTheLinkBody() {
        let provider = FinanceBankProvider.comdirect
        #expect(provider.fields.map(\.key) == ["clientId", "clientSecret", "username", "pin"])
        let body = provider.linkBody(credentials: ["clientId": " User_1 ", "clientSecret": "", "username": "1234567", "pin": "  "],
                                     target: .iban("DE12500105170648489890"))
        #expect(body == .object(["provider": .string("comdirect"), "clientId": .string("User_1"),
                                 "username": .string("1234567"), "iban": .string("DE12500105170648489890"),
                                 "card": .null]))
        // Both keys always go along, the one not used null (a missing one keeps the stored value).
        #expect(provider.linkBody(credentials: [:], target: .card("0175"))
            == .object(["provider": .string("comdirect"), "iban": .null, "card": .string("0175")]))
        #expect(provider.linkBody(credentials: [:], target: .any)
            == .object(["provider": .string("comdirect"), "iban": .null, "card": .null]))
    }

    @Test func readsAnIbanOrACardNumber() {
        #expect(FinanceBankTarget(parsing: "") == .any)
        #expect(FinanceBankTarget(parsing: "  ") == .any)
        #expect(FinanceBankTarget(parsing: "de12 5001 0517 0648 4898 90") == .iban("DE12500105170648489890"))
        #expect(FinanceBankTarget(parsing: "4871 7812 3456 0175") == .card("0175"))
        #expect(FinanceBankTarget(parsing: "0175") == .card("0175"))
        // Masked numbers, as the bank shows them.
        #expect(FinanceBankTarget(parsing: "4871 78XX XXXX 0175") == .card("0175"))
        #expect(FinanceBankTarget(parsing: "XXXX XXXX XXXX 0175") == .card("0175"))
        #expect(FinanceBankTarget(parsing: "•••• 0175") == .card("0175"))
        // Neither.
        #expect(FinanceBankTarget(parsing: "175") == nil)
        #expect(FinanceBankTarget(parsing: "Visa") == nil)
    }

    @Test func showsTheLinkedTargetSoItReadsBackUnchanged() {
        func link(iban: String?, card: String?) -> FinanceBankLink {
            FinanceBankLink(provider: "comdirect", iban: iban, card: card, lastSyncAt: nil)
        }
        let card = FinanceBankTarget(link(iban: nil, card: "0175"))
        #expect(card == .card("0175"))
        #expect(card.text == "•••• 0175")
        #expect(FinanceBankTarget(parsing: card.text) == card)
        let iban = FinanceBankTarget(link(iban: "DE12500105170648489890", card: nil))
        #expect(iban.text == "DE12500105170648489890")
        #expect(FinanceBankTarget(parsing: iban.text) == iban)
        #expect(FinanceBankTarget(link(iban: nil, card: nil)) == .any)
        #expect(FinanceBankTarget(nil).text == "")
    }

    @Test func aNewLinkNeedsEveryCredential() {
        let provider = FinanceBankProvider.comdirect
        let all = ["clientId": "a", "clientSecret": "b", "username": "c", "pin": "d"]
        var some = all
        some["pin"] = " "
        #expect(provider.isComplete(credentials: all, replacing: nil))
        #expect(!provider.isComplete(credentials: some, replacing: nil))
        // An existing link keeps what is left blank.
        let stored = FinanceBankLink(provider: "comdirect", iban: nil, lastSyncAt: nil)
        #expect(provider.isComplete(credentials: [:], replacing: stored))
        // Another provider's link doesn't count.
        #expect(!provider.isComplete(credentials: some, replacing: FinanceBankLink(provider: "other", iban: nil, lastSyncAt: nil)))
    }

    @Test func offersTheSyncInsteadOfTheImport() {
        let cash = account("cash", linked: false), giro = account("giro", linked: true), card = account("card", linked: true)
        #expect(FinanceIntake.of([cash], shownAccount: "") == .importCSV)
        #expect(FinanceIntake.of([], shownAccount: "") == .importCSV)
        #expect(FinanceIntake.of([cash, giro], shownAccount: "giro") == .sync(giro))
        #expect(FinanceIntake.of([cash, giro, card], shownAccount: "") == .choice(linked: [giro, card]))
        #expect(FinanceIntake.of([cash, giro, card], shownAccount: "cash") == .choice(linked: [giro, card]))
        #expect(FinanceIntake.of([cash, giro], shownAccount: "none") == .choice(linked: [giro]))
    }
}
