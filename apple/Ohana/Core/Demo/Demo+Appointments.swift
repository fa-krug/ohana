import Foundation

extension DemoServer {
    /// The demo's appointments routes. A search's runs (with what they found) are in one file per
    /// search (`demo-appointments-searches-<id>-runs.json`); the list, a search's page and a
    /// slot's page are put together from them, the list's file (`demo-appointments.json`: the
    /// searches without their runs, the bookings) and the options (home, people), as the server
    /// does. `/appointments/options` is its file.
    ///
    /// Slot times are a day and a wall-clock time on this device, so the slot of a booking
    /// matches its calendar event: `{{at:N:HH:MM}}` is HH:MM on the day N days from today,
    /// `{{slot:N:HH:MM}}` the same moved off a weekend to the Monday (a practice's hours).
    static func appointments(_ request: Request) -> JSONValue? {
        guard request.method == .get, let path = request.familyPath else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "appointments" else { return nil }
        switch parts.count {
        case 1:
            return appointmentsOverview(request)
        case 3 where parts[1] == "searches":
            return appointmentSearchDetail(parts[2], request)
        case 4 where parts[1] == "searches" && parts[3] == "runs":
            return appointmentRuns(parts[2], request).map { .object(["runs": .array($0)]) }
        case 5 where parts[1] == "searches" && parts[3] == "slots":
            return appointmentSlot(parts[2], resultID: parts[4], request)
        default:
            return nil
        }
    }

    /// Which slot each booking is of (search, result id → calendar event).
    private static let appointmentBookings: [String: String] = [
        "search-pediatrician/101": "event-pediatrician",
    ]

    // MARK: Routes

    /// GET /appointments: the searches with their latest run and its doctors, the bookings.
    private static func appointmentsOverview(_ request: Request) -> JSONValue? {
        guard case var .object(root)? = appointmentsFile("appointments", request),
              case let .array(searches)? = root["searches"] else { return nil }
        root["searches"] = .array(searches.map { withRuns($0, request) })
        return .object(root)
    }

    /// GET /appointments/searches/{id}: the search and the family's home.
    private static func appointmentSearchDetail(_ id: String, _ request: Request) -> JSONValue? {
        guard let search = appointmentSearch(id, request) else { return nil }
        return .object(["search": search, "home": request.json("appointments-options")?["home"] ?? .null])
    }

    /// GET /appointments/searches/{id}/slots/{resultId}: a slot of any of the search's runs, with
    /// its booking.
    private static func appointmentSlot(_ id: String, resultID: String, _ request: Request) -> JSONValue? {
        guard let result = Int(resultID), let search = appointmentSearch(id, request),
              let runs = appointmentRuns(id, request) else { return nil }
        let doctors = runs.flatMap { run -> [JSONValue] in
            if case let .array(doctors)? = run["doctors"] { doctors } else { [] }
        }
        guard let slot = doctors.first(where: { $0["resultId"]?.doubleValue == Double(result) }) else { return nil }
        let options = request.json("appointments-options")
        let label = search["specialityLabel"]?.stringValue ?? ""
        return .object([
            "slot": slot,
            "searchId": .string(id),
            "searchName": search["name"] ?? .string(""),
            "specialityLabel": .string(label.isEmpty ? search["specialitySlug"]?.stringValue ?? "" : label),
            "insuranceSector": search["insuranceSector"] ?? .string(""),
            "homeLat": options?["home"]?["lat"] ?? .null,
            "homeLng": options?["home"]?["lng"] ?? .null,
            "booking": appointmentBooking(id, result, request),
            "searchEnabled": search["enabled"] ?? .bool(true),
            "people": options?["people"] ?? .array([]),
        ])
    }

    // MARK: Parts

    /// A search of the list with its runs filled in.
    private static func appointmentSearch(_ id: String, _ request: Request) -> JSONValue? {
        guard case let .array(searches)? = appointmentsFile("appointments", request)?["searches"],
              let search = searches.first(where: { $0["id"]?.stringValue == id }) else { return nil }
        return withRuns(search, request)
    }

    /// The search's latest run and the earliest slot per doctor of its latest finished run
    /// (serialize.ts `serializeSearch`).
    private static func withRuns(_ search: JSONValue, _ request: Request) -> JSONValue {
        guard case var .object(fields) = search, let id = fields["id"]?.stringValue else { return search }
        let runs = appointmentRuns(id, request) ?? []
        fields["latestRun"] = runs.first?["run"] ?? .null
        let shown = runs.first { $0["run"]?["status"]?.stringValue != "RUNNING" }
        fields["doctors"] = shown?["doctors"] ?? .array([])
        return .object(fields)
    }

    private static func appointmentRuns(_ id: String, _ request: Request) -> [JSONValue]? {
        guard case let .array(runs)? = appointmentsFile("appointments-searches-\(id)-runs", request)?["runs"] else { return nil }
        return runs
    }

    /// The booking of a slot as the slot page gets it, from its calendar event in the list.
    private static func appointmentBooking(_ searchID: String, _ result: Int, _ request: Request) -> JSONValue {
        guard let eventID = appointmentBookings["\(searchID)/\(result)"],
              case let .array(booked)? = appointmentsFile("appointments", request)?["booked"],
              let event = booked.first(where: { $0["id"]?.stringValue == eventID }) else { return .null }
        return .object([
            "eventId": .string(eventID),
            "date": event["date"] ?? .null,
            "start": event["start"] ?? .null,
            "end": event["end"] ?? .null,
            "person": event["person"] ?? .string(""),
        ])
    }

    // MARK: Files

    private static let slotPlaceholder = /\{\{(at|slot):(-?\d+):(\d{1,2}):(\d{2})\}\}/

    /// A file of the module, templated, with its slot times (see `appointments`).
    private static func appointmentsFile(_ name: String, _ request: Request) -> JSONValue? {
        guard let data = request.fixture(name) else { return nil }
        let text = String(decoding: data, as: UTF8.self).replacing(slotPlaceholder) { match in
            var day = request.today.adding(days: Int(match.output.2) ?? 0)
            if match.output.1 == "slot" {
                while day.weekday == 1 || day.weekday == 7 { day = day.adding(days: 1) }
            }
            let components = DateComponents(year: day.year, month: day.month, day: day.day,
                                            hour: Int(match.output.3) ?? 0, minute: Int(match.output.4) ?? 0)
            guard let date = Day.calendar.date(from: components) else { return String(match.output.0) }
            return timestamp(date)
        }
        return try? APIClient.decoder.decode(JSONValue.self, from: Data(text.utf8))
    }
}
