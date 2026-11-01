import Foundation

// The appointments module's data as the server sends it (server/lib/appointments/serialize.ts,
// server/lib/appointments/app-routes.ts, server/lib/calendar/events.ts `PublicEvent`).

/// One doctor's earliest slot of a run (`DoctorSlot`).
struct AppointmentDoctorSlot: Codable, Hashable, Identifiable {
    let resultId: Int
    let doctorName: String
    let doctorSubtitle: String
    let speciality: String
    let practiceName: String
    let motiveLabel: String
    let bookingUrl: String
    /// ISO timestamp.
    let slot: String
    let isNextSlot: Bool
    let practiceAddress: String
    let practiceCity: String
    let practiceZipcode: String
    let practiceLatitude: String
    let practiceLongitude: String
    /// "doctolib" | "jameda"
    let source: String

    var id: Int { resultId }
    var date: Date? { Date.server(slot) }
    var day: Day? { date.map { Day($0) } }
    var sourceName: String { source == "jameda" ? "jameda" : "Doctolib" }

    /// Street, then zip code and city.
    var address: String {
        let city = [practiceZipcode, practiceCity].filter { !$0.isEmpty }.joined(separator: " ")
        return [practiceAddress, city].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// The practice's coordinates, when the source gave them.
    var coordinate: (lat: Double, lng: Double)? {
        guard let lat = Double(practiceLatitude), let lng = Double(practiceLongitude) else { return nil }
        return (lat, lng)
    }

    /// The provider's booking page; scraped data, so only ever http(s).
    var bookingURL: URL? { AppointmentLogic.safeURL(bookingUrl) }
}

/// A run of a search (`RunSummary`).
struct AppointmentRunSummary: Codable, Hashable, Identifiable {
    let id: String
    /// RUNNING | OK | NO_AVAILABILITY | ERROR (and INTERRUPTED from older runs)
    let status: String
    let startedAt: String
    let finishedAt: String?
    let errorMessage: String
    let doctorsFound: Int
    let doctorsMatched: Int
    let slotsFound: Int
    let notified: Bool
    /// MANUAL | SCHEDULE
    let triggeredBy: String
}

/// A doctor (with the reason for the visit) the search skips (`IgnoredItem`).
struct AppointmentIgnoredItem: Codable, Hashable, Identifiable {
    let id: Int
    let doctorName: String
    let motiveLabel: String
    let providerSlug: String
    let motiveId: Int
}

/// A search with its latest run and results (`SearchListItem`).
struct AppointmentSearch: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let sources: String
    let specialitySlug: String
    let specialityLabel: String
    let jamedaSpecialitySlug: String
    let jamedaSpecialityLabel: String
    let jamedaSpecialityType: String
    let jamedaInsuranceType: String
    let jamedaKidsFriendly: Bool
    let jamedaVideo: String
    let locationLabel: String
    let latitude: String
    let longitude: String
    let insuranceSector: String
    let dayLimit: Int
    let maxPages: Int
    let enabled: Bool
    let scheduleType: String
    let scheduleMinutes: Int?
    let cron: String
    let notifyOnlyEarlier: Bool
    /// Also pushed to the app (servers from before push to the app don't send it).
    let notifyApp: Bool?
    let lastRunAt: String?
    let lastStatus: String
    let nextRunAt: String?
    let runRequested: Bool
    let channelIds: [String]
    let latestRun: AppointmentRunSummary?
    let doctors: [AppointmentDoctorSlot]
    let ignored: [AppointmentIgnoredItem]

    /// Queued or running: the pages poll until it's done.
    var isBusy: Bool { runRequested || latestRun?.status == "RUNNING" }

    /// The badge: queued while "run now" waits for the worker, else the latest run's status.
    var badgeStatus: String? { runRequested ? "QUEUED" : latestRun?.status }

    var hasError: Bool { latestRun?.status == "ERROR" && !isBusy }
}

/// An event in the calendar (`PublicEvent`); here the booked appointments.
struct AppointmentEvent: Codable, Hashable, Identifiable {
    let id: String
    let date: String
    let start: String?
    let end: String?
    let title: String
    let location: String
    let person: String
    let note: String
    let url: String
    /// manual | appointment
    let source: String
    let searchId: String?
}

/// GET /appointments
struct AppointmentsOverview: Codable, Hashable {
    let searches: [AppointmentSearch]
    let booked: [AppointmentEvent]
}

/// A notification channel as the search form offers it (no secrets).
struct AppointmentChannelOption: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let provider: String
    let enabled: Bool
}

/// The family's home address (`HomeDto`).
struct AppointmentHome: Codable, Hashable {
    let address: String
    let lat: Double
    let lng: Double
}

/// GET /appointments/options
struct AppointmentOptions: Codable, Hashable {
    let channels: [AppointmentChannelOption]
    /// The family's members by name: "who is it for".
    let people: [String]
    let home: AppointmentHome?
}

/// GET /appointments/searches/{id}
struct AppointmentSearchDetail: Codable, Hashable {
    let search: AppointmentSearch
    let home: AppointmentHome?
}

/// A run with what it found (`RunWithResults`).
struct AppointmentRunWithResults: Codable, Hashable, Identifiable {
    let run: AppointmentRunSummary
    let doctors: [AppointmentDoctorSlot]

    var id: String { run.id }
}

/// GET /appointments/searches/{id}/runs
struct AppointmentRunsResponse: Codable, Hashable {
    let runs: [AppointmentRunWithResults]
}

/// A slot marked as booked: its calendar event.
struct AppointmentBookingInfo: Codable, Hashable {
    let eventId: String
    let date: String
    let start: String?
    let end: String?
    let person: String
}

/// GET /appointments/searches/{id}/slots/{resultId} (`SlotDetailData` + booking state)
struct AppointmentSlotDetail: Codable, Hashable {
    let slot: AppointmentDoctorSlot
    let searchId: String
    let searchName: String
    let specialityLabel: String
    let insuranceSector: String
    let homeLat: Double?
    let homeLng: Double?
    let booking: AppointmentBookingInfo?
    let searchEnabled: Bool
    let people: [String]
    /// Whom a booking is likely for (the search's last booking, or the name in its name); nil
    /// from older servers.
    let suggestedPerson: String?
}

/// POST /appointments/searches/{id}/slots/{resultId}/book
struct AppointmentBookingInput: Codable, Hashable {
    /// "YYYY-MM-DD"
    var date: String
    /// "HH:MM"
    var start: String
    var end: String?
    var person: String
    var note: String
    var stopSearch: Bool
}

struct AppointmentBookingResponse: Codable, Hashable {
    let eventId: String
}

struct AppointmentCreatedResponse: Codable, Hashable {
    let id: String
}

/// Autocomplete: GET /geocode?q= (`LocationSuggestion`)
struct AppointmentLocationSuggestion: Codable, Hashable, Identifiable {
    let label: String
    let latitude: String
    let longitude: String

    var id: String { "\(label)|\(latitude)|\(longitude)" }
}

/// Autocomplete: GET /appointments/doctolib-specialities?q=
struct AppointmentSpecialitySuggestion: Codable, Hashable, Identifiable {
    let slug: String
    let label: String

    var id: String { slug }
}

/// Autocomplete: GET /appointments/jameda-terms?q= (`JamedaTerm`)
struct AppointmentJamedaTerm: Codable, Hashable, Identifiable {
    let slug: String
    let label: String
    /// specialization | leistung | erkrankung
    let type: String

    var id: String { "\(type)/\(slug)" }
}

/// What saves a search (`SearchInput` of server/lib/appointments/schema.ts): POST
/// /appointments/searches, PATCH /appointments/searches/{id}.
struct AppointmentSearchInput: Codable, Hashable {
    var name = ""
    var sources = "doctolib"
    var specialitySlug = ""
    var specialityLabel = ""
    var jamedaSpecialitySlug = ""
    var jamedaSpecialityLabel = ""
    var jamedaSpecialityType = "leistung"
    var jamedaInsuranceType = ""
    var jamedaKidsFriendly = false
    var jamedaVideo = "any"
    var latitude = ""
    var longitude = ""
    var locationLabel = ""
    var insuranceSector = ""
    var dayLimit = 14
    var maxPages = 3
    var enabled = true
    var scheduleType = "MINUTES"
    var scheduleMinutes: Int? = 30
    var cron = ""
    var notifyOnlyEarlier = false
    /// Also push to the family's app devices; nil: the server's (on for a new search, unchanged
    /// for an edit).
    var notifyApp: Bool?
    var channelIds: [String] = []

    init() {}

    /// A stored search as the input that saves it again.
    init(_ s: AppointmentSearch) {
        name = s.name
        sources = s.sources
        specialitySlug = s.specialitySlug
        specialityLabel = s.specialityLabel
        jamedaSpecialitySlug = s.jamedaSpecialitySlug
        jamedaSpecialityLabel = s.jamedaSpecialityLabel
        jamedaSpecialityType = s.jamedaSpecialityType
        jamedaInsuranceType = s.jamedaInsuranceType
        jamedaKidsFriendly = s.jamedaKidsFriendly
        jamedaVideo = s.jamedaVideo
        latitude = s.latitude
        longitude = s.longitude
        locationLabel = s.locationLabel
        insuranceSector = s.insuranceSector
        dayLimit = s.dayLimit
        maxPages = s.maxPages
        enabled = s.enabled
        scheduleType = s.scheduleType
        scheduleMinutes = s.scheduleMinutes
        cron = s.cron
        notifyOnlyEarlier = s.notifyOnlyEarlier
        notifyApp = s.notifyApp
        channelIds = s.channelIds
    }

    private enum CodingKeys: String, CodingKey {
        case name, sources, specialitySlug, specialityLabel, jamedaSpecialitySlug, jamedaSpecialityLabel,
             jamedaSpecialityType, jamedaInsuranceType, jamedaKidsFriendly, jamedaVideo, latitude, longitude,
             locationLabel, insuranceSector, dayLimit, maxPages, enabled, scheduleType, scheduleMinutes, cron,
             notifyOnlyEarlier, notifyApp, channelIds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sources = try c.decodeIfPresent(String.self, forKey: .sources) ?? "doctolib"
        specialitySlug = try c.decodeIfPresent(String.self, forKey: .specialitySlug) ?? ""
        specialityLabel = try c.decodeIfPresent(String.self, forKey: .specialityLabel) ?? ""
        jamedaSpecialitySlug = try c.decodeIfPresent(String.self, forKey: .jamedaSpecialitySlug) ?? ""
        jamedaSpecialityLabel = try c.decodeIfPresent(String.self, forKey: .jamedaSpecialityLabel) ?? ""
        jamedaSpecialityType = try c.decodeIfPresent(String.self, forKey: .jamedaSpecialityType) ?? "leistung"
        jamedaInsuranceType = try c.decodeIfPresent(String.self, forKey: .jamedaInsuranceType) ?? ""
        jamedaKidsFriendly = try c.decodeIfPresent(Bool.self, forKey: .jamedaKidsFriendly) ?? false
        jamedaVideo = try c.decodeIfPresent(String.self, forKey: .jamedaVideo) ?? "any"
        latitude = try c.decodeIfPresent(String.self, forKey: .latitude) ?? ""
        longitude = try c.decodeIfPresent(String.self, forKey: .longitude) ?? ""
        locationLabel = try c.decodeIfPresent(String.self, forKey: .locationLabel) ?? ""
        insuranceSector = try c.decodeIfPresent(String.self, forKey: .insuranceSector) ?? ""
        dayLimit = try c.decodeIfPresent(Int.self, forKey: .dayLimit) ?? 14
        maxPages = try c.decodeIfPresent(Int.self, forKey: .maxPages) ?? 3
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scheduleType = try c.decodeIfPresent(String.self, forKey: .scheduleType) ?? "MINUTES"
        scheduleMinutes = try c.decodeIfPresent(Int.self, forKey: .scheduleMinutes)
        cron = try c.decodeIfPresent(String.self, forKey: .cron) ?? ""
        notifyOnlyEarlier = try c.decodeIfPresent(Bool.self, forKey: .notifyOnlyEarlier) ?? false
        notifyApp = try c.decodeIfPresent(Bool.self, forKey: .notifyApp)
        channelIds = try c.decodeIfPresent([String].self, forKey: .channelIds) ?? []
    }

    /// As the web form sends it: `scheduleMinutes` only for MINUTES (else null, explicitly).
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(sources, forKey: .sources)
        try c.encode(specialitySlug, forKey: .specialitySlug)
        try c.encode(specialityLabel, forKey: .specialityLabel)
        try c.encode(jamedaSpecialitySlug, forKey: .jamedaSpecialitySlug)
        try c.encode(jamedaSpecialityLabel, forKey: .jamedaSpecialityLabel)
        try c.encode(jamedaSpecialityType, forKey: .jamedaSpecialityType)
        try c.encode(jamedaInsuranceType, forKey: .jamedaInsuranceType)
        try c.encode(jamedaKidsFriendly, forKey: .jamedaKidsFriendly)
        try c.encode(jamedaVideo, forKey: .jamedaVideo)
        try c.encode(latitude, forKey: .latitude)
        try c.encode(longitude, forKey: .longitude)
        try c.encode(locationLabel, forKey: .locationLabel)
        try c.encode(insuranceSector, forKey: .insuranceSector)
        try c.encode(dayLimit, forKey: .dayLimit)
        try c.encode(maxPages, forKey: .maxPages)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(scheduleType, forKey: .scheduleType)
        if scheduleType == "MINUTES", let scheduleMinutes {
            try c.encode(scheduleMinutes, forKey: .scheduleMinutes)
        } else {
            try c.encodeNil(forKey: .scheduleMinutes)
        }
        try c.encode(cron, forKey: .cron)
        try c.encode(notifyOnlyEarlier, forKey: .notifyOnlyEarlier)
        try c.encodeIfPresent(notifyApp, forKey: .notifyApp)
        try c.encode(channelIds, forKey: .channelIds)
    }

    // MARK: Sources as two switches (the stored string is derived)

    var doctolibOn: Bool {
        get { sources == "doctolib" || sources == "both" }
        set { sources = AppointmentLogic.sources(doctolib: newValue, jameda: jamedaOn) }
    }

    var jamedaOn: Bool {
        get { sources == "jameda" || sources == "both" }
        set { sources = AppointmentLogic.sources(doctolib: doctolibOn, jameda: newValue) }
    }
}

/// A field of the search editor a problem belongs to (`AppointmentLogic.issues`).
enum AppointmentSearchField: Hashable {
    case name, location, doctolibSpeciality, jamedaSpeciality, dayLimit, maxPages, interval, cron
}

/// How often a search runs, as the editor offers it: presets first, an interval of its own, and
/// a cron expression for those who open "Advanced" (`AppointmentLogic.schedule(of:)` / `apply`).
enum AppointmentSchedule: Hashable, CaseIterable, Identifiable {
    case every5Minutes, every15Minutes, every30Minutes, hourly, daily
    /// Every N minutes, N chosen in a field.
    case customInterval
    case cron

    var id: Self { self }

    /// The choices of the "How often" picker (cron is switched on under Advanced).
    static let presets: [AppointmentSchedule] = [.every5Minutes, .every15Minutes, .every30Minutes, .hourly, .daily, .customInterval]
}

/// Where the app's screens go inside the shell's navigation stack.
enum AppointmentRoute: Hashable {
    case search(String)
    case history(String)
    case slot(searchID: String, resultID: Int)
}

/// What the module's root does with an app route (`family.open`): push a page, open the editor
/// for a new search, or show the list.
enum AppointmentRouteAction: Hashable {
    case push(AppointmentRoute)
    case newSearch
    case list
}

extension AppointmentRoute {
    static func from(_ route: AppRoute) -> AppointmentRouteAction {
        switch route {
        case let .appointmentSearch(id):
            return .push(.search(id))
        case let .appointmentSlot(searchID, resultID):
            guard let result = Int(resultID) else { return .push(.search(searchID)) }
            return .push(.slot(searchID: searchID, resultID: result))
        case .newAppointmentSearch:
            return .newSearch
        default:
            return .list
        }
    }
}

/// How often the appointment pages reload (the web's use-auto-refresh.ts `useRunRefresh`): every
/// 3 s while a run is queued or running, else every 45 s; only while the app is active.
enum AppointmentRefresh {
    static func interval(busy: Bool) -> Duration {
        busy ? .seconds(3) : .seconds(45)
    }
}
