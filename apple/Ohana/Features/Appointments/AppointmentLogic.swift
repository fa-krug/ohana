import Foundation

/// The module's pure logic: what the web app's lib/appointments (summary.ts, distance.ts,
/// google-search.ts, jameda/city.ts, schema.ts) and components/appointments compute.
enum AppointmentLogic {
    // MARK: Sources

    /// The stored `sources` value of the two switches ("none" when both are off).
    static func sources(doctolib: Bool, jameda: Bool) -> String {
        switch (doctolib, jameda) {
        case (true, true): "both"
        case (true, false): "doctolib"
        case (false, true): "jameda"
        case (false, false): "none"
        }
    }

    // MARK: Validation (searchInputSchema)

    /// What keeps the input from saving, in the server's words; empty when it's fine.
    static func problems(_ searchInput: AppointmentSearchInput) -> [String] {
        issues(searchInput).map(\.message)
    }

    /// The problems by the field they belong to, so the editor shows each at its field.
    static func issues(_ searchInput: AppointmentSearchInput) -> [(field: AppointmentSearchField, message: String)] {
        var out: [(field: AppointmentSearchField, message: String)] = []
        let name = searchInput.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { out.append((.name, String(localized: "Give the search a name."))) }
        if name.count > 200 { out.append((.name, String(localized: "The name is too long (max. 200)."))) }
        if searchInput.latitude.trimmingCharacters(in: .whitespaces).isEmpty || searchInput.longitude.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((.location, String(localized: "Pick a location from the suggestions.")))
        }
        if searchInput.doctolibOn && searchInput.specialitySlug.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((.doctolibSpeciality, String(localized: "Pick a Doctolib speciality.")))
        }
        if searchInput.jamedaOn && searchInput.jamedaSpecialitySlug.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append((.jamedaSpeciality, String(localized: "Pick a jameda speciality.")))
        }
        if !(1...365).contains(searchInput.dayLimit) {
            out.append((.dayLimit, String(localized: "Within (days) must be between 1 and 365.")))
        }
        if !(1...20).contains(searchInput.maxPages) {
            out.append((.maxPages, String(localized: "Result pages must be between 1 and 20.")))
        }
        if searchInput.scheduleType == "MINUTES", !(1...1440).contains(searchInput.scheduleMinutes ?? 0) {
            out.append((.interval, String(localized: "The interval must be between 1 and 1440 minutes.")))
        }
        if searchInput.scheduleType == "CRON" {
            let fields = searchInput.cron.split(whereSeparator: \.isWhitespace)
            if fields.count != 5 {
                out.append((.cron, String(localized: "A cron expression has five fields (m h dom mon dow).")))
            }
        }
        if searchInput.cron.trimmingCharacters(in: .whitespaces).count > 100 {
            out.append((.cron, String(localized: "The cron expression is too long (max. 100).")))
        }
        return out
    }

    // MARK: Schedule in plain words

    /// The editor's "How often" choice of a stored schedule (`scheduleType`, `scheduleMinutes`).
    static func schedule(of searchInput: AppointmentSearchInput) -> AppointmentSchedule {
        switch searchInput.scheduleType {
        case "MINUTES":
            switch searchInput.scheduleMinutes {
            case 5: .every5Minutes
            case 15: .every15Minutes
            case 30: .every30Minutes
            default: .customInterval
            }
        case "HOURLY": .hourly
        case "CRON": .cron
        default: .daily
        }
    }

    /// Stores a "How often" choice. A custom interval keeps the minutes there are (else an hour);
    /// a cron schedule keeps its expression (it's typed under Advanced).
    static func apply(_ schedule: AppointmentSchedule, to searchInput: inout AppointmentSearchInput) {
        switch schedule {
        case .every5Minutes: searchInput.scheduleType = "MINUTES"; searchInput.scheduleMinutes = 5
        case .every15Minutes: searchInput.scheduleType = "MINUTES"; searchInput.scheduleMinutes = 15
        case .every30Minutes: searchInput.scheduleType = "MINUTES"; searchInput.scheduleMinutes = 30
        case .hourly: searchInput.scheduleType = "HOURLY"
        case .daily: searchInput.scheduleType = "DAILY"
        case .customInterval:
            if searchInput.scheduleType != "MINUTES" { searchInput.scheduleMinutes = searchInput.scheduleMinutes ?? 60 }
            searchInput.scheduleType = "MINUTES"
        case .cron: searchInput.scheduleType = "CRON"
        }
    }

    // MARK: Summaries (lib/appointments/summary.ts)

    /// Specialities of every active source, then the place and the insurance.
    static func criteriaSummary(_ savedSearch: AppointmentSearch) -> String {
        let doctolib = savedSearch.sources == "doctolib" || savedSearch.sources == "both"
        let jameda = savedSearch.sources == "jameda" || savedSearch.sources == "both"
        let both = doctolib && jameda
        var specialities: [String] = []
        if doctolib {
            let label = savedSearch.specialityLabel.isEmpty ? savedSearch.specialitySlug : savedSearch.specialityLabel
            if !label.isEmpty { specialities.append(both ? "Doctolib: \(label)" : label) }
        }
        if jameda {
            let label = savedSearch.jamedaSpecialityLabel.isEmpty ? savedSearch.jamedaSpecialitySlug : savedSearch.jamedaSpecialityLabel
            if !label.isEmpty { specialities.append(both ? "jameda: \(label)" : label) }
        }
        var parts = [specialities.isEmpty ? "—" : specialities.joined(separator: " · ")]
        if !savedSearch.locationLabel.isEmpty { parts.append(savedSearch.locationLabel) }
        if !savedSearch.insuranceSector.isEmpty { parts.append(insuranceLabel(savedSearch.insuranceSector)) }
        return parts.joined(separator: " · ")
    }

    /// "every 30 min", "hourly", "cron: …" or "not scheduled".
    static func scheduleSummary(enabled: Bool, type: String, minutes: Int?, cron: String) -> String {
        if !enabled { return String(localized: "not scheduled") }
        switch type {
        case "MINUTES": return String(localized: "every \(minutes ?? 0) min")
        case "CRON": return String(localized: "cron: \(cron)")
        case "HOURLY": return String(localized: "hourly")
        default: return String(localized: "daily")
        }
    }

    static func scheduleSummary(_ savedSearch: AppointmentSearch) -> String {
        scheduleSummary(enabled: savedSearch.enabled, type: savedSearch.scheduleType, minutes: savedSearch.scheduleMinutes, cron: savedSearch.cron)
    }

    /// Doctolib's insurance sector ("" | public | private).
    static func insuranceLabel(_ sector: String) -> String {
        switch sector {
        case "public": String(localized: "Public")
        case "private": String(localized: "Private")
        default: String(localized: "Unknown")
        }
    }

    /// A run's (or the queue's) status as the badge says it.
    static func statusLabel(_ status: String) -> String {
        switch status {
        case "OK": String(localized: "found")
        case "NO_AVAILABILITY": String(localized: "nothing free")
        case "ERROR": String(localized: "error")
        case "RUNNING": String(localized: "running")
        case "QUEUED": String(localized: "queued")
        default: status.lowercased()
        }
    }

    static func termTypeLabel(_ type: String) -> String {
        switch type {
        case "specialization": String(localized: "Speciality")
        case "erkrankung": String(localized: "Condition")
        default: String(localized: "Treatment")
        }
    }

    // MARK: Results

    /// The doctors' slots by day, days ascending, each day's slots by time.
    static func groupedByDay(_ doctors: [AppointmentDoctorSlot]) -> [(day: Day?, slots: [AppointmentDoctorSlot])] {
        let sorted = doctors.sorted { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        var out: [(day: Day?, slots: [AppointmentDoctorSlot])] = []
        for slot in sorted {
            let day = slot.day
            if let last = out.last, last.day == day {
                out[out.count - 1].slots.append(slot)
            } else {
                out.append((day, [slot]))
            }
        }
        return out
    }

    // MARK: Distance (lib/appointments/distance.ts)

    /// Great-circle distance in km.
    static func haversineKm(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let earthRadiusKm = 6371.0
        let rad = { (degrees: Double) in degrees * .pi / 180 }
        let dLat = rad(lat2 - lat1)
        let dLng = rad(lng2 - lng1)
        let chordSquared = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2)
        return 2 * earthRadiusKm * asin(sqrt(chordSquared))
    }

    /// "2.4 km" (one decimal under 10 km), in the user's locale.
    static func formatKm(_ km: Double, locale: Locale = .current) -> String {
        let digits = km < 10 ? 1 : 0
        return km.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " km"
    }

    /// The distance of a slot's practice from home, when both are known.
    static func distance(of slot: AppointmentDoctorSlot, homeLat: Double?, homeLng: Double?, locale: Locale = .current) -> String? {
        guard let homeLat, let homeLng, let point = slot.coordinate else { return nil }
        return formatKm(haversineKm(homeLat, homeLng, point.lat, point.lng), locale: locale)
    }

    // MARK: Links

    /// Scraped links: only http(s).
    static func safeURL(_ text: String) -> URL? {
        let lower = text.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    /// Google search for the doctor (lib/appointments/google-search.ts).
    static func googleSearchURL(_ parts: [String]) -> URL {
        let query = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        var urlComponents = URLComponents(string: "https://www.google.com/search")!
        urlComponents.queryItems = [URLQueryItem(name: "q", value: query)]
        return urlComponents.url!
    }

    /// The practice in Apple Maps.
    static func mapsURL(lat: Double, lng: Double, name: String) -> URL {
        var urlComponents = URLComponents(string: "https://maps.apple.com/")!
        urlComponents.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lng)"), URLQueryItem(name: "q", value: name)]
        return urlComponents.url!
    }

    /// The search on Doctolib (search-form.tsx `doctolibPreviewUrl`).
    static func doctolibPreviewURL(_ searchInput: AppointmentSearchInput) -> URL? {
        guard !searchInput.specialitySlug.isEmpty, !searchInput.latitude.isEmpty, !searchInput.longitude.isEmpty else { return nil }
        var urlComponents = URLComponents(string: "https://www.doctolib.de/search")!
        var items = [
            URLQueryItem(name: "around_me", value: "true"),
            URLQueryItem(name: "keyword", value: searchInput.specialitySlug),
            URLQueryItem(name: "latitude", value: searchInput.latitude),
            URLQueryItem(name: "longitude", value: searchInput.longitude),
        ]
        if !searchInput.insuranceSector.isEmpty { items.append(URLQueryItem(name: "insuranceSector", value: searchInput.insuranceSector)) }
        urlComponents.queryItems = items
        return urlComponents.url
    }

    /// The search on jameda (search-form.tsx `jamedaPreviewUrl`).
    static func jamedaPreviewURL(_ searchInput: AppointmentSearchInput) -> URL? {
        let loc = (searchInput.locationLabel.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !loc.isEmpty else { return nil }
        var extra: [URLQueryItem] = []
        if !searchInput.jamedaInsuranceType.isEmpty { extra.append(URLQueryItem(name: "filters[insurance_types][]", value: searchInput.jamedaInsuranceType)) }
        if searchInput.jamedaKidsFriendly { extra.append(URLQueryItem(name: "filters[kids_friendly][]", value: "true")) }
        if searchInput.jamedaVideo == "only" { extra.append(URLQueryItem(name: "filters[online_only][]", value: "true")) }
        if searchInput.jamedaSpecialityType == "specialization", !searchInput.jamedaSpecialitySlug.isEmpty {
            let city = citySlug(searchInput.locationLabel)
            guard !city.isEmpty else { return nil }
            var specialityComponents = URLComponents(string: "https://www.jameda.de/\(searchInput.jamedaSpecialitySlug)/\(city)")!
            specialityComponents.queryItems = extra.isEmpty ? nil : extra
            return specialityComponents.url
        }
        guard !searchInput.jamedaSpecialityLabel.isEmpty else { return nil }
        var urlComponents = URLComponents(string: "https://www.jameda.de/suchen")!
        urlComponents.queryItems = [URLQueryItem(name: "q", value: searchInput.jamedaSpecialityLabel), URLQueryItem(name: "loc", value: loc)] + extra
        return urlComponents.url
    }

    /// jameda's city path: "München, Deutschland" → "muenchen" (lib/appointments/jameda/city.ts).
    static func citySlug(_ label: String) -> String {
        var rawSlug = (label.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            rawSlug = rawSlug.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        var dash = false
        for ch in rawSlug.unicodeScalars {
            if (97...122).contains(ch.value) || (48...57).contains(ch.value) {
                out.unicodeScalars.append(ch)
                dash = false
            } else if !dash {
                out.append("-")
                dash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    // MARK: Booking

    /// The slot's local day and time ("YYYY-MM-DD", "HH:MM") on this device.
    static func localParts(_ date: Date, calendar: Calendar = .current) -> (date: String, time: String) {
        let dateParts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (
            String(format: "%04d-%02d-%02d", dateParts.year!, dateParts.month!, dateParts.day!),
            String(format: "%02d:%02d", dateParts.hour!, dateParts.minute!)
        )
    }

    /// "HH:MM" of a time picked in a DatePicker.
    static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
        localParts(date, calendar: calendar).time
    }

    /// A date at the given day and "HH:MM", for the pickers.
    static func date(day: String, time: String?, calendar: Calendar = .current) -> Date? {
        guard let parsedDay = Day(day) else { return nil }
        let hm = (time ?? "").split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: parsedDay.year, month: parsedDay.month, day: parsedDay.day,
                                                  hour: hm.count == 2 ? hm[0] : 0, minute: hm.count == 2 ? hm[1] : 0))
    }

    /// "Tue, 3 Nov 2026, 09:30" of a booking (book-dialog.tsx `formatBooking`).
    static func formatBooking(date: String, start: String?) -> String {
        guard let parsedDay = Day(date) else { return date }
        let day = parsedDay.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        if let start, !start.isEmpty { return "\(day), \(start)" }
        return day
    }

    /// A slot's date and time.
    static func formatSlot(_ iso: String, full: Bool = false) -> String {
        guard let date = Date.server(iso) else { return iso }
        return date.formatted(date: full ? .complete : .abbreviated, time: .shortened)
    }

    /// A booked appointment's day in the calendar ("YYYY-MM-DD"; the calendar itself when
    /// unreadable).
    static func calendarRoute(date: String) -> AppRoute {
        Day(date).map { .calendarDay($0) } ?? .module(.calendar)
    }

    /// "2 more doctors" under a search card's first three (`appointments.moreResults`).
    static func moreDoctors(_ count: Int) -> AttributedString {
        AttributedString(localized: "^[\(count) more doctor](inflect: true)")
    }

    /// "3 found · 2 matching · 1 appointment" of a run (`appointments.run.*`).
    static func runCounts(found: Int, matched: Int, slots: Int) -> AttributedString {
        AttributedString(localized: "\(found) found · \(matched) matching · ")
            + AttributedString(localized: "^[\(slots) appointment](inflect: true)")
    }
}
