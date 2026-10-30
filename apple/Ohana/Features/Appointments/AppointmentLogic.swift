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
    static func problems(_ i: AppointmentSearchInput) -> [String] {
        var out: [String] = []
        let name = i.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { out.append(String(localized: "Give the search a name.")) }
        if name.count > 200 { out.append(String(localized: "The name is too long (max. 200).")) }
        if i.latitude.trimmingCharacters(in: .whitespaces).isEmpty || i.longitude.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(String(localized: "Pick a location from the suggestions."))
        }
        if i.doctolibOn && i.specialitySlug.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(String(localized: "Pick a Doctolib speciality."))
        }
        if i.jamedaOn && i.jamedaSpecialitySlug.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(String(localized: "Pick a jameda speciality."))
        }
        if !(1...365).contains(i.dayLimit) { out.append(String(localized: "Within (days) must be between 1 and 365.")) }
        if !(1...20).contains(i.maxPages) { out.append(String(localized: "Result pages must be between 1 and 20.")) }
        if i.scheduleType == "MINUTES", !(1...1440).contains(i.scheduleMinutes ?? 0) {
            out.append(String(localized: "The interval must be between 1 and 1440 minutes."))
        }
        if i.scheduleType == "CRON" {
            let fields = i.cron.split(whereSeparator: \.isWhitespace)
            if fields.count != 5 { out.append(String(localized: "A cron expression has five fields (m h dom mon dow).")) }
        }
        if i.cron.trimmingCharacters(in: .whitespaces).count > 100 {
            out.append(String(localized: "The cron expression is too long (max. 100)."))
        }
        return out
    }

    // MARK: Summaries (lib/appointments/summary.ts)

    /// Specialities of every active source, then the place and the insurance.
    static func criteriaSummary(_ s: AppointmentSearch) -> String {
        let doctolib = s.sources == "doctolib" || s.sources == "both"
        let jameda = s.sources == "jameda" || s.sources == "both"
        let both = doctolib && jameda
        var specialities: [String] = []
        if doctolib {
            let label = s.specialityLabel.isEmpty ? s.specialitySlug : s.specialityLabel
            if !label.isEmpty { specialities.append(both ? "Doctolib: \(label)" : label) }
        }
        if jameda {
            let label = s.jamedaSpecialityLabel.isEmpty ? s.jamedaSpecialitySlug : s.jamedaSpecialityLabel
            if !label.isEmpty { specialities.append(both ? "jameda: \(label)" : label) }
        }
        var parts = [specialities.isEmpty ? "—" : specialities.joined(separator: " · ")]
        if !s.locationLabel.isEmpty { parts.append(s.locationLabel) }
        if !s.insuranceSector.isEmpty { parts.append(insuranceLabel(s.insuranceSector)) }
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

    static func scheduleSummary(_ s: AppointmentSearch) -> String {
        scheduleSummary(enabled: s.enabled, type: s.scheduleType, minutes: s.scheduleMinutes, cron: s.cron)
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
        let r = 6371.0
        let rad = { (d: Double) in d * .pi / 180 }
        let dLat = rad(lat2 - lat1)
        let dLng = rad(lng2 - lng1)
        let a = pow(sin(dLat / 2), 2) + cos(rad(lat1)) * cos(rad(lat2)) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(sqrt(a))
    }

    /// "2.4 km" (one decimal under 10 km), in the user's locale.
    static func formatKm(_ km: Double, locale: Locale = .current) -> String {
        let digits = km < 10 ? 1 : 0
        return km.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " km"
    }

    /// The distance of a slot's practice from home, when both are known.
    static func distance(of slot: AppointmentDoctorSlot, homeLat: Double?, homeLng: Double?, locale: Locale = .current) -> String? {
        guard let homeLat, let homeLng, let p = slot.coordinate else { return nil }
        return formatKm(haversineKm(homeLat, homeLng, p.lat, p.lng), locale: locale)
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
        let q = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        return c.url!
    }

    /// The practice in Apple Maps.
    static func mapsURL(lat: Double, lng: Double, name: String) -> URL {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lng)"), URLQueryItem(name: "q", value: name)]
        return c.url!
    }

    /// The search on Doctolib (search-form.tsx `doctolibPreviewUrl`).
    static func doctolibPreviewURL(_ i: AppointmentSearchInput) -> URL? {
        guard !i.specialitySlug.isEmpty, !i.latitude.isEmpty, !i.longitude.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.doctolib.de/search")!
        var items = [
            URLQueryItem(name: "around_me", value: "true"),
            URLQueryItem(name: "keyword", value: i.specialitySlug),
            URLQueryItem(name: "latitude", value: i.latitude),
            URLQueryItem(name: "longitude", value: i.longitude),
        ]
        if !i.insuranceSector.isEmpty { items.append(URLQueryItem(name: "insuranceSector", value: i.insuranceSector)) }
        c.queryItems = items
        return c.url
    }

    /// The search on jameda (search-form.tsx `jamedaPreviewUrl`).
    static func jamedaPreviewURL(_ i: AppointmentSearchInput) -> URL? {
        let loc = (i.locationLabel.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard !loc.isEmpty else { return nil }
        var extra: [URLQueryItem] = []
        if !i.jamedaInsuranceType.isEmpty { extra.append(URLQueryItem(name: "filters[insurance_types][]", value: i.jamedaInsuranceType)) }
        if i.jamedaKidsFriendly { extra.append(URLQueryItem(name: "filters[kids_friendly][]", value: "true")) }
        if i.jamedaVideo == "only" { extra.append(URLQueryItem(name: "filters[online_only][]", value: "true")) }
        if i.jamedaSpecialityType == "specialization", !i.jamedaSpecialitySlug.isEmpty {
            let city = citySlug(i.locationLabel)
            guard !city.isEmpty else { return nil }
            var c = URLComponents(string: "https://www.jameda.de/\(i.jamedaSpecialitySlug)/\(city)")!
            c.queryItems = extra.isEmpty ? nil : extra
            return c.url
        }
        guard !i.jamedaSpecialityLabel.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.jameda.de/suchen")!
        c.queryItems = [URLQueryItem(name: "q", value: i.jamedaSpecialityLabel), URLQueryItem(name: "loc", value: loc)] + extra
        return c.url
    }

    /// jameda's city path: "München, Deutschland" → "muenchen" (lib/appointments/jameda/city.ts).
    static func citySlug(_ label: String) -> String {
        var s = (label.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var out = ""
        var dash = false
        for ch in s.unicodeScalars {
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
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (
            String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!),
            String(format: "%02d:%02d", c.hour!, c.minute!)
        )
    }

    /// "HH:MM" of a time picked in a DatePicker.
    static func timeString(_ date: Date, calendar: Calendar = .current) -> String {
        localParts(date, calendar: calendar).time
    }

    /// A date at the given day and "HH:MM", for the pickers.
    static func date(day: String, time: String?, calendar: Calendar = .current) -> Date? {
        guard let d = Day(day) else { return nil }
        let hm = (time ?? "").split(separator: ":").compactMap { Int($0) }
        return calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day,
                                                  hour: hm.count == 2 ? hm[0] : 0, minute: hm.count == 2 ? hm[1] : 0))
    }

    /// "Tue, 3 Nov 2026, 09:30" of a booking (book-dialog.tsx `formatBooking`).
    static func formatBooking(date: String, start: String?) -> String {
        guard let d = Day(date) else { return date }
        let day = d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
        if let start, !start.isEmpty { return "\(day), \(start)" }
        return day
    }

    /// A slot's date and time.
    static func formatSlot(_ iso: String, full: Bool = false) -> String {
        guard let date = Date.server(iso) else { return iso }
        return date.formatted(date: full ? .complete : .abbreviated, time: .shortened)
    }
}
