import AppIntents
import Foundation

// Siri / Shortcuts actions that put something into Ohana without opening the app: an item on the
// shopping list (in Reminders), an event in the calendar, a recipe from a web page. The calendar
// and recipes talk to the server like the app (`IntentConnection`), with the family the app shows.

// MARK: Shopping list

/// "Add milk to the shopping list": adds a reminder to the Reminders list the family's shopping
/// goes to on this device (`ShoppingReminders`; chosen in the app). Works offline: it needs no
/// server.
struct AddShoppingReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Shopping List"
    static let description = IntentDescription("Adds an item to the family’s shopping list in Reminders, the list chosen in Ohana.")
    static let openAppWhenRun = false

    @Parameter(title: "Item", requestValueDialog: "What should go on the shopping list?")
    var item: String

    @Parameter(title: "Quantity", default: 1)
    var quantity: Double

    @Parameter(title: "Unit", description: "An abbreviation like l, g or kg; without one, pieces.")
    var unit: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$quantity) \(\.$unit) \(\.$item) to the shopping list")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw OhanaIntentError.emptyText }
        guard let amount = ShoppingIntentLogic.quantityText(quantity) else { throw OhanaIntentError.badQuantity }
        let title = ShoppingIntentLogic.title(name: name, quantity: amount, unit: unit)
        let list = try await Self.add(title)
        return .result(dialog: IntentDialog("Added \(title) to \(list)."))
    }

    /// Adds `title` to the family's shopping list in Reminders; the list's name.
    @MainActor
    private static func add(_ title: String) throws -> String {
        guard let connection = SharedConnection.load(),
              let familyID = connection.familyID ?? UserDefaults.standard.string(forKey: "selectedFamilyID")
        else { throw OhanaIntentError.notConnected }
        guard let listID = ShoppingReminders.shared.settings(server: connection.server, familyID: familyID).listID else {
            throw OhanaIntentError.noRemindersList
        }
        let store = RemindersStore.shared
        store.refreshAccess()
        guard store.access.isGranted else { throw OhanaIntentError.noRemindersAccess }
        guard let list = store.list(listID) else { throw OhanaIntentError.noRemindersList }
        do {
            try store.add(ReminderDraft(title: title), to: listID)
        } catch {
            throw OhanaIntentError.server(error.localizedDescription)
        }
        return list.title
    }
}

/// The shopping intent's pieces that don't need Reminders.
nonisolated enum ShoppingIntentLogic {
    /// The quantity as a decimal ("1", "2.5", "0.333"); nil when it isn't above 0.
    static func quantityText(_ value: Double) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        let rounded = (value * 1000).rounded() / 1000
        guard rounded > 0 else { return nil }
        return rounded.formatted(.number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(.fractionLength(0...3)))
    }

    /// The reminder's title: "Milk" for one without a unit, else like the shopping sync's,
    /// "2 l Milk", "1 kg Flour".
    static func title(name: String, quantity: String, unit: String?, locale: Locale = .current) -> String {
        let unit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if unit.isEmpty, quantity == "1" { return name }
        return [ShoppingQuantity.format(quantity, locale: locale), unit, name].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: Calendar

/// "Add an event": a timed or all-day event in the family calendar (POST …/events).
struct AddEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Event"
    static let description = IntentDescription("Adds an event to the family calendar in Ohana.")
    static let openAppWhenRun = false

    @Parameter(title: "Title", requestValueDialog: "What’s the event?")
    var eventTitle: String

    @Parameter(title: "Date", requestValueDialog: "When is it?")
    var date: Date

    @Parameter(title: "All day", default: false)
    var allDay: Bool

    @Parameter(title: "End", description: "When it ends; on a later day for an event of several days.")
    var end: Date?

    @Parameter(title: "Location")
    var location: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$eventTitle) on \(\.$date)") {
            \.$allDay
            \.$end
            \.$location
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let title = eventTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw OhanaIntentError.emptyText }
        let body = EventIntentBody(title: title, start: date, end: end, allDay: allDay, location: location)
        let connection = try await IntentConnection.load()
        let api = connection.api
        try await OhanaIntentError.wrapping { try await api.perform(.post, "/events", body: body) }
        let when = allDay ? date.formatted(date: .complete, time: .omitted) : date.formatted(date: .complete, time: .shortened)
        return .result(dialog: IntentDialog("Added “\(title)” to the calendar on \(when)."))
    }
}

/// The body of POST /events (server/lib/calendar/events.ts `eventInputSchema`): the first and
/// last day and the wall-clock times in the device's calendar and time zone; no times for an
/// all-day event. An end on a later day makes an event of several days; one that isn't after the
/// start is left out.
nonisolated struct EventIntentBody: Encodable, Equatable {
    var date: String
    var endDate: String?
    var start: String?
    var end: String?
    var title: String
    var location: String?

    init(title: String, start: Date, end: Date?, allDay: Bool, location: String?, calendar: Calendar = .current) {
        self.title = title
        let location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.location = location?.isEmpty == false ? location : nil
        date = Self.day(start, calendar)
        let end = end.flatMap { $0 > start ? $0 : nil }
        if let end, !calendar.isDate(end, inSameDayAs: start) { endDate = Self.day(end, calendar) }
        guard !allDay else { return }
        self.start = Self.time(start, calendar)
        if let end { self.end = Self.time(end, calendar) }
    }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: Recipes

/// "Import a recipe": the server's assistant reads a web page and saves the recipe to "Want to
/// try" (POST …/meals/recipes/import). Takes a URL from the share sheet in a shortcut.
struct ImportRecipeIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Recipe"
    static let description = IntentDescription("Saves the recipe of a web page to “Want to try” in Ohana. The assistant reads the page, which can take a minute or two.")
    static let openAppWhenRun = false

    @Parameter(title: "Web Page", requestValueDialog: "Which web page has the recipe?",
               inputConnectionBehavior: .connectToPreviousIntentResult)
    var url: URL

    static var parameterSummary: some ParameterSummary {
        Summary("Import the recipe from \(\.$url)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw OhanaIntentError.server(String(localized: "That isn’t the address of a web page."))
        }
        let connection = try await IntentConnection.load(requiring: [.meals, .assistant])
        let api = connection.api
        let recipe: ImportedRecipe = try await OhanaIntentError.wrapping {
            let body = try APIClient.encoder.encode(RecipeImportRequest(url: url))
            var req = api.client.request(.post, RecipeImportRequest.path(familyID: api.familyID), body: body)
            req.timeoutInterval = SharedConnection.importTimeout
            let (data, _) = try await api.client.data(for: req)
            return try api.client.decode(ImportedRecipe.self, from: data)
        }
        return .result(dialog: IntentDialog("Saved “\(recipe.title)” to “Want to try”."))
    }
}
