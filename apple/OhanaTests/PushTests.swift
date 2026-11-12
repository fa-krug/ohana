import Foundation
import Testing
import UserNotifications
@testable import Ohana

/// Push to the app (Core/Push): the sealed payload the server makes (the same vector as
/// server/tests/push.test.ts), the server's push info, and the new optional fields.
@MainActor
struct PushTests {
    private let key = Data((0..<32).map { UInt8($0) })
    private let sealed =
        "oKGio6SlpqeoqaqrnToKD3/6Lp0WDPO/Ylj6/DjNNXz9lW5O/mFC/12RV0agtfs8MEdzzcANj+olWPOYM3NkckD/fFEnP2ZxxxHp1drY5B0SicaGlY+WdPaHqJj3Kc3FqOPkeQr+EU+om82TFfDqplQtSA=="

    @Test func opensWhatTheServerSealed() throws {
        let payload = try PushPayload.open(sealed, key: key)
        #expect(payload == PushPayload(v: 1, title: "Hallo", body: "Grüße 👋", path: "/f/fam/calendar", familyId: "fam", event: nil))
    }

    @Test func refusesAnotherKeyOrGarbage() {
        #expect(throws: (any Error).self) { try PushPayload.open(sealed, key: Data(repeating: 1, count: 32)) }
        #expect(throws: (any Error).self) { try PushPayload.open("not base64!", key: key) }
        #expect(throws: (any Error).self) { try PushPayload.open("AAAA", key: key) }
    }

    @Test func showsThePayloadInsteadOfTheFallback() throws {
        let content = UNMutableNotificationContent()
        content.body = "New notification from Ohana"
        content.userInfo = ["o": sealed]
        try PushPayload.open(sealed, key: key).apply(to: content)
        #expect(content.title == "Hallo")
        #expect(content.body == "Grüße 👋")
        #expect(content.threadIdentifier == "fam")
        #expect(content.userInfo["path"] as? String == "/f/fam/calendar")
        #expect(content.userInfo["o"] == nil)
    }

    @Test func setsTheIconsNumberOnlyWhenThePayloadHasOne() {
        let content = UNMutableNotificationContent()
        content.badge = 5
        PushPayload(v: 1, title: "T", body: "B").apply(to: content)
        #expect(content.badge == 5)
        PushPayload(v: 1, title: "T", body: "B", badge: 2).apply(to: content)
        #expect(content.badge == 2)
        PushPayload(v: 1, title: "T", body: "B", badge: 0).apply(to: content)
        #expect(content.badge == 0)
    }

    @Test func readsTheNumbersAhead() throws {
        let payload = try JSONDecoder().decode(PushPayload.self, from: Data(
            #"{"v":1,"title":"T","body":"B","badge":2,"badgeTomorrow":{"day":"2026-11-08","count":3},"badgeSteps":[{"at":"2026-11-07T18:00","count":4}]}"#.utf8))
        #expect(payload.badgeTomorrow == BadgeSchedule.Next(day: "2026-11-08", count: 3))
        #expect(payload.badgeSteps == [BadgeSchedule.Step(at: "2026-11-07T18:00", count: 4)])
        let answer = try JSONDecoder().decode(BadgeCount.self, from: Data(#"{"count":1}"#.utf8))
        #expect(answer.count == 1 && answer.tomorrow == nil && answer.steps == nil)
    }

    @Test func switchesTheNumberAtTheNextMidnightForOlderServers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 21))!
        let requests = BadgeSchedule.requests(steps: nil, tomorrow: .init(day: "2026-11-08", count: 4), now: evening, calendar: calendar)
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.identifier == BadgeSchedule.midnightIdentifier)
        #expect(BadgeSchedule.isBadgeOnly(request.identifier))
        #expect(request.content.badge == 4)
        #expect(request.content.title.isEmpty && request.content.body.isEmpty && request.content.sound == nil)
        let trigger = try #require(request.trigger as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats)
        #expect(trigger.dateComponents.day == 8 && trigger.dateComponents.hour == 0 && trigger.dateComponents.minute == 0)
        // A day already begun, or not a day: nothing.
        #expect(BadgeSchedule.requests(steps: nil, tomorrow: .init(day: "2026-11-07", count: 1), now: evening, calendar: calendar).isEmpty)
        #expect(BadgeSchedule.requests(steps: nil, tomorrow: .init(day: "tomorrow", count: 1), now: evening, calendar: calendar).isEmpty)
    }

    @Test func switchesTheNumberWhenChoresBecomeDue() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let early = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 6, minute: 30))!
        let steps: [BadgeSchedule.Step] = [
            .init(at: "2026-11-07T06:00", count: 1), // passed
            .init(at: "2026-11-07T07:00", count: 2),
            .init(at: "2026-11-08T00:00", count: 1),
            .init(at: "soon", count: 9),
        ]
        // With steps, the midnight number isn't scheduled on its own.
        let requests = BadgeSchedule.requests(steps: steps, tomorrow: .init(day: "2026-11-08", count: 1), now: early, calendar: calendar)
        #expect(requests.map { $0.content.badge?.intValue } == [2, 1])
        #expect(Set(requests.map(\.identifier)).count == 2)
        #expect(requests.allSatisfy { BadgeSchedule.isBadgeOnly($0.identifier) && BadgeSchedule.identifiers.contains($0.identifier) })
        let morning = try #require(requests.first?.trigger as? UNCalendarNotificationTrigger)
        #expect(morning.dateComponents.day == 7 && morning.dateComponents.hour == 7 && morning.dateComponents.minute == 0)
        #expect(BadgeSchedule.requests(steps: [], tomorrow: .init(day: "2026-11-08", count: 1), now: early, calendar: calendar).isEmpty)
        #expect(!BadgeSchedule.isBadgeOnly("de.fa-krug.Ohana.cook-timer.1"))
    }

    @Test func tellsTheServerTheDevicesClock() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 6, minute: 5))!
        #expect(AppBadge.clock(now, calendar: calendar) == ["today": "2026-11-07", "time": "06:05"])
    }

    @Test func runsTheJobJustAfterMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 21))!
        let start = AppBadge.jobStart(after: evening, calendar: calendar)
        #expect(start == calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 0, minute: 5)))
    }

    @Test func knowsWhetherTheServerPushesThroughThisBuildsRelay() throws {
        let on = try JSONDecoder().decode(ServerInfo.self, from: Data("""
        {"name":"Ohana","version":"0.3.0","apiVersion":1,"modules":["calendar"],"push":{"relay":"https://ohana-push.fa-krug.de"}}
        """.utf8))
        #expect(on.push?.relay == URL(string: "https://ohana-push.fa-krug.de"))
        let off = try JSONDecoder().decode(ServerInfo.self, from: Data("""
        {"name":"Ohana","version":"0.3.0","apiVersion":1,"modules":["calendar"],"push":null}
        """.utf8))
        #expect(off.push == nil)
        let older = try JSONDecoder().decode(ServerInfo.self, from: Data("""
        {"name":"Ohana","version":"0.2.0","apiVersion":1,"modules":["calendar"]}
        """.utf8))
        #expect(older.push == nil)
        #expect(!PushNotifications.isAvailable(off))
        #expect(PushNotifications.sameRelay(URL(string: "https://OHANA-push.fa-krug.de/")!, URL(string: "https://ohana-push.fa-krug.de")!))
        #expect(!PushNotifications.sameRelay(URL(string: "https://other.example")!, URL(string: "https://ohana-push.fa-krug.de")!))
    }

    @Test func sendsTheAppSwitchesOnlyWhenKnown() throws {
        func json(_ value: some Encodable) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
        var search = AppointmentSearchInput()
        #expect(try json(search)["notifyApp"] == nil)
        search.notifyApp = false
        #expect(try json(search)["notifyApp"] as? Bool == false)

        let unknown = FamilyEventPref(event: "coverage_gap", enabled: true, channelIds: nil, app: nil, hasChannels: true)
        #expect(try json(unknown.input)["app"] == nil)
        let off = FamilyEventPref(event: "coverage_gap", enabled: true, channelIds: nil, app: false, hasChannels: true)
        #expect(try json(off.input)["app"] as? Bool == false)
    }
}
