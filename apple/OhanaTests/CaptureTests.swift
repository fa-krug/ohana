import Foundation
import Testing
@testable import Ohana

/// The Siri / Shortcuts actions' requests and the share extension's shared pieces.
struct CaptureTests {
    static func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    static func date(_ text: String) -> Date {
        // Wall-clock time in Berlin.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/Berlin")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    static func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Events

    @Test func timedEventUsesTheWallClock() throws {
        let body = EventIntentBody(title: "Dentist", start: Self.date("2026-11-06 15:00"),
                                   end: Self.date("2026-11-06 16:30"), allDay: false,
                                   location: "  Main St 1 ", calendar: Self.calendar())
        #expect(body == EventIntentBody(title: "Dentist", start: Self.date("2026-11-06 15:00"),
                                        end: Self.date("2026-11-06 16:30"), allDay: false,
                                        location: "Main St 1", calendar: Self.calendar()))
        let json = try Self.json(body)
        #expect(json["date"] as? String == "2026-11-06")
        #expect(json["start"] as? String == "15:00")
        #expect(json["end"] as? String == "16:30")
        #expect(json["title"] as? String == "Dentist")
        #expect(json["location"] as? String == "Main St 1")
    }

    @Test func allDayEventHasNoTimes() throws {
        let body = EventIntentBody(title: "Trip", start: Self.date("2026-11-06 00:30"),
                                   end: Self.date("2026-11-06 18:00"), allDay: true,
                                   location: " ", calendar: Self.calendar())
        let json = try Self.json(body)
        #expect(json["date"] as? String == "2026-11-06")
        #expect(json["start"] == nil)
        #expect(json["end"] == nil)
        #expect(json["location"] == nil)
    }

    @Test func endOnAnotherDayOrBeforeTheStartIsLeftOut() {
        let calendar = Self.calendar()
        let nextDay = EventIntentBody(title: "Party", start: Self.date("2026-11-06 20:00"),
                                      end: Self.date("2026-11-07 01:00"), allDay: false, location: nil, calendar: calendar)
        #expect(nextDay.start == "20:00")
        #expect(nextDay.end == nil)
        let before = EventIntentBody(title: "Oops", start: Self.date("2026-11-06 20:00"),
                                     end: Self.date("2026-11-06 19:00"), allDay: false, location: nil, calendar: calendar)
        #expect(before.end == nil)
    }

    @Test func dayFollowsTheCalendarsTimeZone() {
        // 23:30 in Berlin is already the next day in Tokyo.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let body = EventIntentBody(title: "Call", start: Self.date("2026-11-06 23:30"), end: nil,
                                   allDay: false, location: nil, calendar: tokyo)
        #expect(body.date == "2026-11-07")
        #expect(body.start == "07:30")
    }

    // MARK: Shopping

    static let units: [ShoppingIntentLogic.Unit] = [
        .init(id: 1, abbreviation: "g", nameEn: "gram", nameDe: "Gramm"),
        .init(id: 2, abbreviation: "kg", nameEn: "kilogram", nameDe: "Kilogramm"),
        .init(id: 3, abbreviation: "l", nameEn: "liter", nameDe: "Liter"),
        .init(id: 4, abbreviation: "Stk", nameEn: "piece", nameDe: "Stück"),
        .init(id: 5, abbreviation: "EL", nameEn: "tablespoon", nameDe: "Esslöffel"),
    ]

    @Test func quantityIsADecimalString() {
        #expect(ShoppingIntentLogic.quantityText(1) == "1")
        #expect(ShoppingIntentLogic.quantityText(2.5) == "2.5")
        #expect(ShoppingIntentLogic.quantityText(1.0 / 3) == "0.333")
        #expect(ShoppingIntentLogic.quantityText(1500) == "1500")
        #expect(ShoppingIntentLogic.quantityText(0) == nil)
        #expect(ShoppingIntentLogic.quantityText(-1) == nil)
        #expect(ShoppingIntentLogic.quantityText(.nan) == nil)
    }

    @Test func unitsMatchByAbbreviationOrName() {
        let units = Self.units
        #expect(ShoppingIntentLogic.unit(named: nil, in: units)?.id == 4)
        #expect(ShoppingIntentLogic.unit(named: "  ", in: units)?.id == 4)
        #expect(ShoppingIntentLogic.unit(named: "L", in: units)?.id == 3)
        #expect(ShoppingIntentLogic.unit(named: "litres", in: units)?.id == 3)
        #expect(ShoppingIntentLogic.unit(named: "Kilogramm", in: units)?.id == 2)
        #expect(ShoppingIntentLogic.unit(named: "grams", in: units)?.id == 1)
        #expect(ShoppingIntentLogic.unit(named: "el", in: units)?.id == 5)
        #expect(ShoppingIntentLogic.unit(named: "pieces", in: units)?.id == 4)
        #expect(ShoppingIntentLogic.unit(named: "Stück", in: units)?.id == 4)
        #expect(ShoppingIntentLogic.unit(named: "bucket", in: units) == nil)
        // Without "Stk" the default is the first unit.
        #expect(ShoppingIntentLogic.unit(named: nil, in: Array(units.prefix(2)))?.id == 1)
    }

    @Test func addItemBody() throws {
        let json = try Self.json(ShoppingIntentLogic.AddItem(name: "Milk", quantity: "2", unitId: 3))
        #expect(json["name"] as? String == "Milk")
        #expect(json["quantity"] as? String == "2")
        #expect(json["unitId"] as? Int == 3)
        let overview = try JSONDecoder().decode(ShoppingIntentLogic.Overview.self,
                                                from: Data(#"{"lists":[],"latest":null}"#.utf8))
        #expect(overview.latest == nil)
    }

    // MARK: Recipe import

    @Test func importBodyCleansWhatThePageGave() throws {
        let url = URL(string: "https://example.com/pasta")!
        let request = RecipeImportRequest(url: url, text: "  \n ", title: " Pasta ", imageUrl: "javascript:alert(1)")
        #expect(request == RecipeImportRequest(url: url, title: "Pasta"))
        let json = try Self.json(request)
        #expect(json["url"] as? String == "https://example.com/pasta")
        #expect(json["title"] as? String == "Pasta")
        #expect(json["text"] == nil)
        #expect(json["imageUrl"] == nil)

        let long = RecipeImportRequest(url: url, text: String(repeating: "a", count: 150_000),
                                       imageUrl: "https://example.com/p.jpg")
        #expect(long.text?.count == RecipeImportRequest.maxText)
        #expect(long.imageUrl == "https://example.com/p.jpg")
        #expect(RecipeImportRequest.path(familyID: "f1") == "/api/v1/families/f1/meals/recipes/import")
    }

    @Test func readsSafarisPreprocessingResult() {
        let page = SharedPage(preprocessingResults: [
            "url": "https://example.com/pasta", "title": " Pasta ", "text": "{\"@type\":\"Recipe\"}\n\nPasta",
            "imageUrl": "",
        ])
        #expect(page.url?.absoluteString == "https://example.com/pasta")
        #expect(page.title == "Pasta")
        #expect(page.text?.hasPrefix("{") == true)
        #expect(page.imageUrl == nil)
        #expect(SharedPage(preprocessingResults: ["url": "file:///etc/passwd"]).url == nil)
        let merged = SharedPage(url: URL(string: "https://a.example")).merging(SharedPage(title: "From the item"))
        #expect(merged.title == "From the item")
        #expect(merged.url?.host() == "a.example")
    }

    @Test func sharedConnectionBuildsRequests() throws {
        let connection = SharedConnection(server: URL(string: "https://ohana.example/base")!, token: "t0k", familyID: "f2")
        let req = connection.request("POST", "/api/v1/families/f2/meals/recipes/import", body: Data("{}".utf8),
                                     timeout: SharedConnection.importTimeout)
        #expect(req.url?.absoluteString == "https://ohana.example/base/api/v1/families/f2/meals/recipes/import")
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.timeoutInterval == 180)

        let families = [SharedConnection.Family(id: "f1", name: "One"), SharedConnection.Family(id: "f2", name: "Two")]
        #expect(SharedConnection.pick(families, selected: "f2")?.name == "Two")
        #expect(SharedConnection.pick(families, selected: "gone")?.name == "One")
        #expect(SharedConnection.pick([], selected: nil) == nil)
    }

    @Test func errorTexts() {
        #expect(ServerErrorText.message(from: Data(#"{"error":"No recipe found on that page"}"#.utf8)) == "No recipe found on that page")
        #expect(ServerErrorText.message(from: Data(#"{"message":"Nope"}"#.utf8)) == "Nope")
        #expect(ServerErrorText.message(from: Data(#"{"error":""}"#.utf8)) == nil)
        #expect(ServerErrorText.message(from: Data("<html>".utf8)) == nil)
        #expect(SharedError.server(status: 422, message: "No recipe found on that page").localizedDescription
            == "No recipe found on that page")
        #expect(SharedError.server(status: 502, message: nil).localizedDescription == "The server answered with an error (502).")
        #expect(SharedError.server(status: 401, message: "Invalid token").localizedDescription
            == "Your session has ended. Open Ohana and sign in again.")
        #expect(SharedError.notConnected.localizedDescription == "Open Ohana and connect your server first.")
    }

    @MainActor
    @Test func intentErrorsKeepTheServersWords() async {
        await #expect(throws: OhanaIntentError.server("You can only view this family")) {
            try await OhanaIntentError.wrapping { () async throws -> Int in
                throw APIError.http(status: 403, message: "You can only view this family")
            }
        }
        await #expect(throws: OhanaIntentError.sessionEnded) {
            try await OhanaIntentError.wrapping { () async throws -> Int in throw APIError.unauthorized(nil) }
        }
        await #expect(throws: OhanaIntentError.noShoppingList) {
            try await OhanaIntentError.wrapping { () async throws -> Int in throw OhanaIntentError.noShoppingList }
        }
        #expect(String(localized: OhanaIntentError.server("Nope").localizedStringResource) == "Nope")
        #expect(String(localized: OhanaIntentError.noShoppingList.localizedStringResource)
            == "There’s no shopping list yet: it comes with the meal plan.")
    }
}
