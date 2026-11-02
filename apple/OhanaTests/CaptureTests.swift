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

    @Test func endOnAnotherDaySpansDaysAndOneBeforeTheStartIsLeftOut() {
        let calendar = Self.calendar()
        let nextDay = EventIntentBody(title: "Party", start: Self.date("2026-11-06 20:00"),
                                      end: Self.date("2026-11-07 01:00"), allDay: false, location: nil, calendar: calendar)
        #expect(nextDay.start == "20:00" && nextDay.end == "01:00")
        #expect(nextDay.date == "2026-11-06" && nextDay.endDate == "2026-11-07")
        let trip = EventIntentBody(title: "Trip", start: Self.date("2026-11-06 00:00"),
                                   end: Self.date("2026-11-08 00:00"), allDay: true, location: nil, calendar: calendar)
        #expect(trip.endDate == "2026-11-08" && trip.start == nil && trip.end == nil)
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

    @Test func quantityIsADecimalString() {
        #expect(ShoppingIntentLogic.quantityText(1) == "1")
        #expect(ShoppingIntentLogic.quantityText(2.5) == "2.5")
        #expect(ShoppingIntentLogic.quantityText(1.0 / 3) == "0.333")
        #expect(ShoppingIntentLogic.quantityText(1500) == "1500")
        #expect(ShoppingIntentLogic.quantityText(0) == nil)
        #expect(ShoppingIntentLogic.quantityText(-1) == nil)
        #expect(ShoppingIntentLogic.quantityText(.nan) == nil)
    }

    @Test func theItemsTitleInReminders() {
        let en = Locale(identifier: "en_US")
        #expect(ShoppingIntentLogic.title(name: "Milk", quantity: "1", unit: nil, locale: en) == "Milk")
        #expect(ShoppingIntentLogic.title(name: "Milk", quantity: "1", unit: "  ", locale: en) == "Milk")
        #expect(ShoppingIntentLogic.title(name: "Milk", quantity: "2", unit: "l", locale: en) == "2 l Milk")
        #expect(ShoppingIntentLogic.title(name: "Flour", quantity: "1", unit: "kg", locale: en) == "1 kg Flour")
        #expect(ShoppingIntentLogic.title(name: "Eggs", quantity: "6", unit: nil, locale: en) == "6 Eggs")
        #expect(ShoppingIntentLogic.title(name: "Milch", quantity: "2.5", unit: "l", locale: Locale(identifier: "de_DE"))
            == "2,5 l Milch")
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
        #expect(page.preprocessed)
        #expect(page.recipe == nil) // the script didn't say: unknown
        #expect(SharedPage(preprocessingResults: ["url": "file:///etc/passwd"]).url == nil)
    }

    @Test func readsTheRecipeThePageScriptFound() {
        let page = SharedPage(preprocessingResults: [
            "url": "https://example.com/pasta", "title": "Pasta | Example", "recipe": true,
            "recipeName": " Pasta al limone ", "recipeImage": "https://example.com/p.jpg",
        ])
        #expect(page.recipe == true)
        #expect(page.recipeName == "Pasta al limone")
        #expect(page.recipeImage == "https://example.com/p.jpg")
        // Through Safari the booleans arrive as NSNumber.
        let bridged = SharedPage(preprocessingResults: ["url": "https://example.com", "recipe": NSNumber(value: false),
                                                         "recipeName": ""])
        #expect(bridged.recipe == false)
        #expect(bridged.recipeName == nil)
    }

    @Test func combinesTheSharedItems() {
        let link = URL(string: "https://example.com/pasta")!
        // A good result is the page; the item's text only fills a missing title.
        let result = SharedPage(preprocessingResults: ["url": "https://example.com/pasta", "text": "Body", "recipe": true])
        let page = SharedPage.combine(result: result, attachmentURL: URL(string: "https://other.example"), itemTitle: "Item")
        #expect(page.url == link && page.title == "Item" && page.text == "Body" && page.recipe == true)

        // Safari's crashed tab: a result without an address. The URL attachment is the page, and
        // nothing of the placeholder (nor the item's copy of its title) is kept.
        let crashed = SharedPage(preprocessingResults: ["url": "", "title": "Webseite abgestürzt", "text": "Neu laden",
                                                        "recipe": false])
        let recovered = SharedPage.combine(result: crashed, attachmentURL: link, itemTitle: "Webseite abgestürzt")
        #expect(recovered == SharedPage(url: link, preprocessed: true))
        #expect(recovered.text == nil && recovered.recipe == nil)
        #expect(SharedPage.combine(result: crashed, attachmentURL: link, itemTitle: "Pasta").title == "Pasta")

        // No address anywhere: Safari handed over a page it couldn't read, or another app shared
        // something that isn't one.
        #expect(SharedPage.combine(result: crashed, attachmentURL: nil, itemTitle: nil).preprocessed)
        let plain = SharedPage.combine(result: nil, attachmentURL: link, itemTitle: "Shared")
        #expect(plain == SharedPage(url: link, title: "Shared"))
        #expect(!SharedPage.combine(result: nil, attachmentURL: nil, itemTitle: nil).preprocessed)
    }

    @Test func backgroundImportBodyAndAnswers() throws {
        let url = URL(string: "https://example.com/pasta")!
        #expect(try Self.json(RecipeImportRequest(url: url))["background"] == nil)
        #expect(try Self.json(RecipeImportRequest(url: url, background: true))["background"] as? Bool == true)
        #expect(RecipeImportRequest.previewPath(familyID: "f1") == "/api/v1/families/f1/meals/recipes/import/preview")
        let preview = try Self.json(RecipePreviewRequest(url: url, title: "  "))
        #expect(preview["url"] as? String == "https://example.com/pasta" && preview["title"] == nil)

        let queued = try JSONDecoder().decode(RecipeImportStarted.self, from: Data("""
        {"import":{"id":"i1","url":"https://example.com/pasta","title":"","imageUrl":null,"status":"waiting",        "error":null,"createdAt":"2026-11-02T10:00:00.000Z"}}
        """.utf8))
        guard case let .queued(job) = queued else { Issue.record("not queued"); return }
        #expect(job.id == "i1" && job.title.isEmpty && job.imageUrl == nil && !job.isFailed)
        // An older server ignores `background` and answers with the saved recipe.
        let old = try JSONDecoder().decode(RecipeImportStarted.self, from: Data(#"{"id":"r1","title":"Pasta"}"#.utf8))
        #expect(old == .imported(ImportedRecipe(id: "r1", title: "Pasta")))
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RecipeImportStarted.self, from: Data("{}".utf8)) }

        let preview2 = try JSONDecoder().decode(RecipePreview.self, from: Data(#"{"recipe":true,"title":"Pasta","imageUrl":null}"#.utf8))
        #expect(preview2 == RecipePreview(recipe: true, title: "Pasta", imageUrl: nil))
        #expect(try JSONDecoder().decode(MealsAIAvailability.self, from: Data(#"{"generate":false,"photos":false,"recipeCount":2}"#.utf8)).generate == false)
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
        await #expect(throws: OhanaIntentError.noRemindersList) {
            try await OhanaIntentError.wrapping { () async throws -> Int in throw OhanaIntentError.noRemindersList }
        }
        #expect(String(localized: OhanaIntentError.server("Nope").localizedStringResource) == "Nope")
        #expect(String(localized: OhanaIntentError.noRemindersList.localizedStringResource)
            == "Choose a Reminders list for the shopping list in Ohana first: Meals → Plan → Shopping List.")
    }
}
