import EventKit
import Foundation
import Testing
@testable import Ohana

private func d(_ s: String) -> Day { Day(s)! }

private let family = "fam1"
private let window = d("2026-10-01")...d("2027-11-01")

private func fields(_ day: String = "2026-11-05", last: String? = nil, start: String? = "09:00", end: String? = "10:00",
                    title: String = "Swimming", person: String = "", note: String = "", url: String = "",
                    rrule: String? = nil) -> OhanaSyncFields {
    OhanaSyncFields(date: d(day), endDate: d(last ?? day), start: start, end: end, title: title, person: person,
                    note: note, url: url, rrule: rrule)
}

private func ohana(_ id: String, _ f: OhanaSyncFields = fields(), externalId: String? = nil,
                   inWindow: Bool? = nil) -> OhanaSyncItem {
    OhanaSyncItem(id: id, externalId: externalId, fields: f, inWindow: inWindow ?? window.contains(f.date))
}

private func apple(_ id: String, key: String? = nil, _ f: AppleSyncFields? = nil, url: URL? = nil,
                   occurrences: [Day: AppleOccurrence]? = nil) -> AppleSyncEvent {
    AppleSyncEvent(localID: id, key: key ?? "ext-\(id)", url: url, fields: f ?? AppleSyncMapping.apple(fields()),
                   occurrences: occurrences)
}

private func copy(of o: OhanaSyncItem, id: String, occurrences: [Day: AppleOccurrence]? = nil) -> AppleSyncEvent {
    apple(id, AppleSyncMapping.apple(o.fields), url: AppleSyncMark.url(family: family, day: o.fields.date, .event(o.id)),
          occurrences: occurrences)
}

private func link(_ o: OhanaSyncItem, _ a: AppleSyncEvent, exceptions: [Day: AppleSyncException] = [:]) -> AppleSyncLink {
    AppleSyncLink(ohanaID: o.id, appleID: a.localID, appleKey: a.key, ohana: o.fields, apple: a.fields, exceptions: exceptions)
}

private func plan(ohana: [OhanaSyncItem] = [], apple: [AppleSyncEvent] = [], links: [AppleSyncLink] = [],
                  canEdit: Bool = true, spans: [AppleSyncSpan]? = nil, entryIDs: Set<String> = [],
                  lookup: [String: AppleSyncLookup] = [:]) -> AppleSyncPlan {
    AppleSyncPlanner.plan(family: family, ohana: ohana, apple: apple, window: window, links: links, canEdit: canEdit,
                          spans: spans, entryIDs: entryIDs) { lookup[$0.appleID] ?? .gone }
}

/// A weekly series on Thursdays from 5 Nov 2026, its first three occurrences listed.
private func weekly(_ id: String = "s1", occurrences: [Day: OhanaOccurrence]? = nil) -> OhanaSyncItem {
    var item = ohana(id, fields(rrule: "FREQ=WEEKLY"))
    for day in ["2026-11-05", "2026-11-12", "2026-11-19"] {
        item.occurrences[d(day)] = .normal
        item.occurrenceFields[d(day)] = fields(day)
    }
    for (day, state) in occurrences ?? [:] {
        item.occurrences[day] = state
        if case let .changed(f) = state { item.occurrenceFields[day] = f }
    }
    return item
}

private let allThere: [Day: AppleOccurrence] = [d("2026-11-05"): .normal, d("2026-11-12"): .normal, d("2026-11-19"): .normal]

struct AppleSyncMappingTests {
    @Test func carriesThePersonAndTheLinkThere() {
        let o = fields(title: "Dentist", person: "Mia", note: "Bring the card", url: "https://doc.example")
        let a = AppleSyncMapping.apple(o)
        #expect(a.title == "Dentist (Mia)")
        #expect(a.notes == "Bring the card\n\nhttps://doc.example")
        // And back: the person and the link stay out of the title and the note.
        #expect(AppleSyncMapping.ohana(a, current: o) == o)
        var edited = a
        edited.title = "Dentist, new (Mia)"
        edited.notes = "Bring the card and the form\n\nhttps://doc.example"
        let back = AppleSyncMapping.ohana(edited, current: o)
        #expect(back.title == "Dentist, new")
        #expect(back.note == "Bring the card and the form")
        #expect(back.person == "Mia")
        #expect(back.url == "https://doc.example")
    }

    @Test func keepsTheDaysAndTheRule() {
        let o = fields("2026-11-05", last: "2026-11-07", start: "18:00", end: "11:00", rrule: "BYDAY=FR;FREQ=WEEKLY")
        #expect(o.rrule == "FREQ=WEEKLY;BYDAY=FR") // the server's way
        let a = AppleSyncMapping.apple(o)
        #expect(a.lastDay == d("2026-11-07"))
        #expect(a.rrule == "FREQ=WEEKLY;BYDAY=FR")
        #expect(AppleSyncMapping.ohana(a, current: o) == o)
        // An end before the start on one day isn't one.
        var oneDay = a
        oneDay.lastDay = oneDay.day
        #expect(AppleSyncMapping.ohana(oneDay, current: nil).end == nil)
    }

    @Test func importsAnAppleEventWithinTheServersLimits() {
        let a = AppleSyncFields(day: d("2026-11-05"), lastDay: d("2026-11-05"), start: nil, end: nil,
                                title: "  ", location: String(repeating: "x", count: 400), notes: "")
        let o = AppleSyncMapping.ohana(a, url: URL(string: "https://club.example/plan"), current: nil)
        #expect(o.title == "Event")
        #expect(o.location.count == 300)
        #expect(o.url == "https://club.example/plan")
        #expect(AppleSyncMapping.ohana(a, url: URL(string: "ohana://f/x/calendar/2026-11-05"), current: nil).url == "")
    }

    @Test func marksOnlyItsOwnFamily() {
        let url = AppleSyncMark.url(family: family, day: d("2026-11-05"), .event("e1"))
        #expect(url.absoluteString == "ohana://f/fam1/calendar/2026-11-05?event=e1")
        #expect(AppleSyncMark(url, family: family) == .event("e1"))
        #expect(AppleSyncMark(url, family: "other") == nil)
        #expect(AppleSyncMark(AppleSyncMark.url(family: family, day: d("2026-11-05"), .entry("vacation")), family: family)
                == .entry("vacation"))
        #expect(AppleSyncMark(URL(string: "https://example.com"), family: family) == nil)
        // The link opens the day in the app.
        #expect(AppRoute.parse(webPath: "/f/fam1/calendar/2026-11-05", tab: nil)?.1 == .calendarDay(d("2026-11-05")))
    }

    @Test func makesRunsOfEntryDaysPerYear() {
        let types: [Int: [CalendarEntryType]] = [
            2026: [CalendarEntryType(id: "vac", year: 2026, name: "Vacation", color: "#0f0", role: .covers)],
            2027: [CalendarEntryType(id: "vac", year: 2027, name: "Urlaub", color: "#0f0", role: .covers)],
        ]
        let entries: [Day: [String]] = [
            d("2026-12-30"): ["vac"], d("2026-12-31"): ["vac"], d("2027-01-01"): ["vac"],
            d("2027-01-04"): ["vac"], d("2026-01-02"): ["vac"], // before the window
            d("2026-11-02"): ["gone"], // a type that isn't there
        ]
        let spans = AppleSyncMapping.spans(entries: entries, types: types, window: window)
        #expect(spans == [
            AppleSyncSpan(typeID: "vac", title: "Vacation", first: d("2026-12-30"), last: d("2026-12-31")),
            AppleSyncSpan(typeID: "vac", title: "Urlaub", first: d("2027-01-01"), last: d("2027-01-01")),
            AppleSyncSpan(typeID: "vac", title: "Urlaub", first: d("2027-01-04"), last: d("2027-01-04")),
        ])
    }

    @Test func turnsOhanasSeriesIntoAppleEventsAndBack() {
        let events = [
            CalendarEventSeries(id: "s1", date: d("2026-11-05"), start: "09:00", end: "10:00", title: "Swimming",
                                rrule: "FREQ=WEEKLY", exdates: [d("2026-11-19"), d("2030-01-01")],
                                overrides: [CalendarEventOverride(occurrence: d("2026-11-12"), date: d("2026-11-13"),
                                                                  endDate: d("2026-11-13"), start: "10:00", end: "11:00",
                                                                  title: "Swimming late")]),
            CalendarEventSeries(id: "e1", date: d("2025-01-01"), start: nil, end: nil, title: "Old"),
        ]
        let listed = [
            CalendarEvent(id: "s1", occurrence: d("2026-11-05"), date: d("2026-11-05"), start: "09:00", end: "10:00",
                          title: "Swimming", rrule: "FREQ=WEEKLY"),
            CalendarEvent(id: "s1", occurrence: d("2026-11-12"), date: d("2026-11-13"), start: "10:00", end: "11:00",
                          title: "Swimming late", rrule: "FREQ=WEEKLY"),
        ]
        let items = AppleCalendarSync.items(events, occurrences: listed, window: window, reach: AppleCalendarSync.reach(window))
        #expect(items[0].inWindow)
        #expect(items[0].occurrences == [
            d("2026-11-05"): .normal,
            d("2026-11-12"): .changed(fields("2026-11-13", start: "10:00", end: "11:00", title: "Swimming late")),
            d("2026-11-19"): .deleted,
        ])
        #expect(!items[1].inWindow)
        #expect(items[1].occurrences.isEmpty)
    }

    @Test func convertsRulesToEventKitAndBack() {
        for text in ["FREQ=DAILY", "FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE", "FREQ=MONTHLY;BYDAY=-1FR",
                     "FREQ=MONTHLY;BYMONTHDAY=15;COUNT=10", "FREQ=YEARLY;BYDAY=2SU;BYMONTH=3",
                     "FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1", "FREQ=WEEKLY;UNTIL=20271231"] {
            let rule = RepeatRule(text)!
            let back = AppleCalendarSync.repeatRule(AppleCalendarSync.ekRule(rule))?.string
            #expect(back == text, "\(text) came back as \(back ?? "nil")")
        }
    }

    @Test func readsAndWritesMultiDayEvents() {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        // Timed over three days.
        let o = fields("2026-11-05", last: "2026-11-07", start: "18:00", end: "11:00")
        AppleCalendarSync.write(o, to: event, isNew: true, rule: true)
        #expect(AppleCalendarSync.fields(event, rule: true) == AppleSyncMapping.apple(o))
        // Without an end: until the end of the last day.
        let open = fields("2026-11-05", last: "2026-11-07", start: "18:00", end: nil)
        AppleCalendarSync.write(open, to: event, isNew: false, rule: true)
        #expect(AppleCalendarSync.fields(event, rule: true) == AppleSyncMapping.apple(open))
        // All day, repeating.
        let allDay = fields("2026-11-05", last: "2026-11-06", start: nil, end: nil, rrule: "FREQ=YEARLY")
        AppleCalendarSync.write(allDay, to: event, isNew: false, rule: true)
        #expect(event.isAllDay)
        #expect(AppleCalendarSync.fields(event, rule: true) == AppleSyncMapping.apple(allDay))
    }
}

struct AppleSyncPlannerTests {
    @Test func copiesNewEventsBothWays() {
        let o = ohana("e1")
        let a = apple("a1", AppleSyncMapping.apple(fields(title: "Football")))
        let p = plan(ohana: [o, ohana("old", fields("2026-01-10"))], apple: [a])
        #expect(p.steps == [.createOhana(a), .createApple(o)]) // not the one before the window
    }

    @Test func leavesUnchangedLinksAlone() {
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        let p = plan(ohana: [o], apple: [a], links: [link(o, a)])
        #expect(p.steps.isEmpty)
        #expect(p.keep == [link(o, a)])
    }

    @Test func sendsTheSideThatChanged() {
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        let l = link(o, a)
        // Ohana made it three days long.
        let longer = ohana("e1", fields(last: "2026-11-07"))
        #expect(plan(ohana: [longer], apple: [a], links: [l]).steps == [.updateApple(longer, appleID: "a1")])
        // Apple moved it.
        var later = a
        later.fields.start = "11:00"
        later.fields.end = "12:00"
        #expect(plan(ohana: [o], apple: [later], links: [l]).steps
                == [.updateOhana(id: "e1", fields(start: "11:00", end: "12:00"), later)])
        // Apple made it repeat.
        var repeating = a
        repeating.fields.rrule = "FREQ=DAILY"
        #expect(plan(ohana: [o], apple: [repeating], links: [l]).steps
                == [.updateOhana(id: "e1", fields(rrule: "FREQ=DAILY"), repeating)])
        // Both: Ohana's wins.
        #expect(plan(ohana: [longer], apple: [later], links: [l]).steps == [.updateApple(longer, appleID: "a1")])
        // A viewer's Apple edit is put back.
        #expect(plan(ohana: [o], apple: [later], links: [l], canEdit: false).steps == [.updateApple(o, appleID: "a1")])
    }

    @Test func deletesWhatWentOnTheOtherSide() {
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        let l = link(o, a)
        #expect(plan(ohana: [], apple: [a], links: [l]).steps == [.deleteApple(appleID: "a1")])
        #expect(plan(ohana: [o], apple: [], links: [l]).steps == [.deleteOhana(id: "e1")])
        // A viewer gets the copy back.
        #expect(plan(ohana: [o], apple: [], links: [l], canEdit: false).steps == [.createApple(o)])
        // Outside the window it is looked up.
        #expect(plan(ohana: [o], apple: [], links: [l], lookup: ["a1": .found(a)]).steps.isEmpty)
    }

    @Test func forgetsLinksOfPastEvents() {
        let o = ohana("e1", fields("2026-01-10"))
        let a = copy(of: o, id: "a1")
        let p = plan(ohana: [o], apple: [], links: [link(o, a)], lookup: ["a1": .found(a)])
        #expect(p.steps.isEmpty)
        #expect(p.keep.isEmpty)
    }

    @Test func findsALinkedEventByItsKeyWhenItsIDChanged() {
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        var renamed = a
        renamed.localID = "a1-new"
        #expect(plan(ohana: [o], apple: [renamed], links: [link(o, a)]).steps.isEmpty)
    }

    @Test func holdsBackDeletingManyOhanaEventsAtOnce() {
        let events = (1...12).map { ohana("e\($0)") }
        let links = events.enumerated().map { i, o in link(o, copy(of: o, id: "a\(i)")) }
        let p = plan(ohana: events, apple: [], links: links)
        #expect(p.heldBack == 12)
        #expect(!p.steps.contains { if case .deleteOhana = $0 { true } else { false } })
        #expect(p.keep.count == 12)
    }

    @Test func linksWhatAnotherDeviceSynced() {
        // Another device copied the Ohana event into the same (iCloud) calendar.
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        #expect(plan(ohana: [o], apple: [a]).steps == [.link(o, a, exceptions: [:])])
        // Another device imported the Apple event.
        let native = apple("a2", key: "uid-2", AppleSyncMapping.apple(fields(title: "Football")))
        let imported = ohana("e2", fields(title: "Football"), externalId: "uid-2")
        #expect(plan(ohana: [imported], apple: [native]).steps == [.link(imported, native, exceptions: [:])])
        // … and it differs: Ohana's wins.
        let renamed = ohana("e2", fields(title: "Football training"), externalId: "uid-2")
        #expect(plan(ohana: [renamed], apple: [native]).steps == [.updateApple(renamed, appleID: "a2")])
    }

    @Test func removesStaleAndDoubleCopies() {
        let o = ohana("e1")
        let a = copy(of: o, id: "a1")
        let twin = copy(of: o, id: "a2")
        let gone = copy(of: ohana("deleted"), id: "a3")
        let p = plan(ohana: [o], apple: [a, twin, gone], links: [link(o, a)])
        #expect(Set(p.steps.map { "\($0)" }) == Set([AppleSyncStep.deleteApple(appleID: "a2"),
                                                     .deleteApple(appleID: "a3")].map { "\($0)" }))
    }

    @Test func leavesOtherFamiliesCopiesAlone() {
        let other = apple("a1", url: AppleSyncMark.url(family: "fam2", day: d("2026-11-05"), .event("x")))
        #expect(plan(apple: [other]).steps.isEmpty)
    }

    @Test func aViewerImportsNothing() {
        #expect(plan(apple: [apple("a1")], canEdit: false).steps.isEmpty)
    }

    @Test func importsASeriesOnceAndItsOccurrencesInTheNextPass() {
        let series = apple("a1", AppleSyncMapping.apple(fields(rrule: "FREQ=WEEKLY")), occurrences: allThere)
        let p = plan(apple: [series])
        #expect(p.steps == [.createOhana(series)])
        #expect(p.needsAnotherPass)
    }

    @Test func syncsOccurrencesDeletedOrChangedOnOneSide() {
        let o = weekly()
        let a = copy(of: o, id: "a1", occurrences: allThere)
        // Deleted in Apple: deleted in Ohana.
        var deletedThere = a
        deletedThere.occurrences![d("2026-11-12")] = nil
        let p1 = plan(ohana: [o], apple: [deletedThere], links: [link(o, a)])
        #expect(p1.steps == [.deleteOhanaOccurrence(id: "s1", day: d("2026-11-12"))])
        #expect(p1.keep[0].exceptions == [d("2026-11-12"): AppleSyncException(ohana: .deleted, apple: .deleted)])
        // Changed in Apple: that occurrence changed in Ohana (the person kept).
        var moved = AppleSyncMapping.apple(fields("2026-11-13"))
        moved.rrule = nil
        var changedThere = a
        changedThere.occurrences![d("2026-11-12")] = .changed(moved)
        #expect(plan(ohana: [o], apple: [changedThere], links: [link(o, a)]).steps
                == [.updateOhanaOccurrence(id: "s1", day: d("2026-11-12"), fields("2026-11-13"))])
        // Deleted and changed in Ohana: in Apple too.
        let changedHere = weekly(occurrences: [d("2026-11-12"): .deleted, d("2026-11-19"): .changed(fields("2026-11-20"))])
        #expect(plan(ohana: [changedHere], apple: [a], links: [link(o, a)]).steps == [
            .deleteAppleOccurrence(appleID: "a1", day: d("2026-11-12"), ohanaID: "s1"),
            .updateAppleOccurrence(appleID: "a1", day: d("2026-11-19"), fields("2026-11-20"), ohanaID: "s1"),
        ])
    }

    @Test func leavesSettledOccurrencesAlone() {
        let o = weekly(occurrences: [d("2026-11-12"): .deleted])
        var a = copy(of: o, id: "a1", occurrences: allThere)
        a.occurrences![d("2026-11-12")] = nil
        let settled = [d("2026-11-12"): AppleSyncException(ohana: .deleted, apple: .deleted)]
        let p = plan(ohana: [o], apple: [a], links: [link(o, a, exceptions: settled)])
        #expect(p.steps.isEmpty)
        #expect(p.keep[0].exceptions == settled)
        // An Apple deletion Ohana took back can't be undone there: they stay apart, quietly.
        let restored = weekly()
        let apart = plan(ohana: [restored], apple: [a], links: [link(o, a, exceptions: settled)])
        #expect(apart.steps.isEmpty)
        #expect(apart.keep[0].exceptions == [d("2026-11-12"): AppleSyncException(ohana: .normal, apple: .deleted)])
    }

    @Test func aViewerPutsOccurrencesBack() {
        let o = weekly()
        var a = copy(of: o, id: "a1", occurrences: allThere)
        var moved = AppleSyncMapping.apple(fields("2026-11-13"))
        moved.rrule = nil
        a.occurrences![d("2026-11-12")] = .changed(moved)
        #expect(plan(ohana: [o], apple: [a], links: [link(o, a)], canEdit: false).steps
                == [.updateAppleOccurrence(appleID: "a1", day: d("2026-11-12"), fields("2026-11-12"), ohanaID: "s1")])
    }

    @Test func keepsTheEntryRunsInStep() {
        let span = AppleSyncSpan(typeID: "vac", title: "Vacation", first: d("2026-11-02"), last: d("2026-11-06"))
        let current = apple("m1", AppleSyncMapping.apple(span),
                            url: AppleSyncMark.url(family: family, day: d("2026-11-02"), .entry("vac")))
        // As it should be: kept, and never imported.
        let kept = plan(apple: [current], spans: [span])
        #expect(kept.steps.isEmpty)
        #expect(kept.keepEntries == ["m1"])
        // Shortened in Ohana: made again.
        let shorter = AppleSyncSpan(typeID: "vac", title: "Vacation", first: d("2026-11-02"), last: d("2026-11-04"))
        #expect(plan(apple: [current], spans: [shorter]).steps == [.deleteEntry(appleID: "m1"), .createEntry(shorter)])
        // Entries turned off: removed.
        #expect(plan(apple: [current], spans: nil).steps == [.deleteEntry(appleID: "m1")])
        // A calendar that lost the link: known by its id.
        var unmarked = current
        unmarked.url = nil
        #expect(plan(apple: [unmarked], spans: [span], entryIDs: ["m1"]).steps.isEmpty)
    }
}
