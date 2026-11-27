import EventKit
import Foundation

// The steps of one sync (`AppleCalendarSync` runs them): what a step does to one side, the links it
// leaves and how the pass ended. `AppleCalendarSync.syncPass` reads both sides and plans, `Steps`
// works the plan through (`AppleSyncStep`, `AppleSyncPlanner`).

extension AppleCalendarSync {
    struct Pass {
        var failed: (any Error)?
        var heldBack = 0
        var changedOhana = false
        var again = false
    }

    /// The plan's steps, worked through one by one: what a step changes, the links it leaves, and
    /// how the pass ended (`AppleSyncStep`, `AppleSyncPlanner`).
    struct Steps {
        let context: FamilyContext
        let calendar: EKCalendar
        let family: String
        let store: EKEventStore
        let events: AppleCalendarSync.AppleEvents
        /// The links as they were before this pass, by Ohana event.
        let previous: [String: AppleSyncLink]
        /// The Ohana events this pass already links.
        let linked: Set<String>
        var pass: Pass
        var links: [AppleSyncLink]
        var entryIDs: [String]
        /// Occurrences whose step failed: their last state stays, so they are tried again.
        var failedDays: [String: Set<Day>] = [:]

        /// One step on Apple's calendar; what it does to Ohana answers in `applyOhana`.
        mutating func apply(_ step: AppleSyncStep) async throws {
            switch step {
            case let .createApple(item):
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                AppleCalendarSync.write(item.fields, to: event, isNew: true, rule: true)
                event.url = AppleSyncMark.url(family: family, day: item.fields.date, .event(item.id))
                try store.save(event, span: .thisEvent, commit: true)
                links.append(AppleCalendarSync.link(item.id, item.fields, event))
            case let .updateApple(item, appleID):
                guard let event = events.masters[appleID] else { return }
                let span: EKSpan = event.hasRecurrenceRules || item.fields.rrule != nil ? .futureEvents : .thisEvent
                AppleCalendarSync.write(item.fields, to: event, isNew: false, rule: true)
                if AppleSyncMark(event.url, family: family) != nil {
                    event.url = AppleSyncMark.url(family: family, day: item.fields.date, .event(item.id))
                }
                try store.save(event, span: span, commit: true)
                let kept = AppleCalendarSync.kept(previous[item.id], rule: item.fields.rrule)
                links.append(AppleCalendarSync.link(item.id, item.fields, event, exceptions: kept))
            case let .link(item, apple, exceptions):
                links.append(AppleSyncLink(ohanaID: item.id, appleID: apple.localID, appleKey: apple.key,
                                           ohana: item.fields, apple: apple.fields, exceptions: exceptions))
            case let .deleteApple(appleID):
                if let event = events.masters[appleID] { try store.remove(event, span: .futureEvents, commit: true) }
            default:
                try await applyAppleOther(step)
            }
        }

        /// One occurrence on Apple's calendar and the all-day events of the entry runs; the steps
        /// that change Ohana answer in `applyOhana`.
        mutating func applyAppleOther(_ step: AppleSyncStep) async throws {
            switch step {
            case let .updateAppleOccurrence(appleID, day, fields, ohanaID):
                guard let event = events.occurrences[AppleCalendarSync.AppleEvents.occurrenceKey(appleID, day)] else {
                    failedDays[ohanaID, default: []].insert(day)
                    return
                }
                AppleCalendarSync.write(fields, to: event, isNew: false, rule: false)
                try store.save(event, span: .thisEvent, commit: true)
            case let .deleteAppleOccurrence(appleID, day, _):
                if let event = events.occurrences[AppleCalendarSync.AppleEvents.occurrenceKey(appleID, day)] {
                    try store.remove(event, span: .thisEvent, commit: true)
                }
            case let .createEntry(span):
                let event = EKEvent(eventStore: store)
                event.calendar = calendar
                event.title = span.title
                event.isAllDay = true
                event.startDate = Day.calendar.startOfDay(for: span.first.date)
                // Noon of the last day: read back as that day however the account stores the end.
                event.endDate = span.last.date
                event.url = AppleSyncMark.url(family: family, day: span.first, .entry(span.typeID))
                try store.save(event, span: .thisEvent, commit: true)
                entryIDs.append(event.calendarItemIdentifier)
            case let .deleteEntry(appleID):
                if let event = events.masters[appleID] { try store.remove(event, span: .futureEvents, commit: true) }
            default:
                try await applyOhana(step)
            }
        }

        /// One step on Ohana: the event made, changed, deleted or only linked, with its occurrences.
        mutating func applyOhana(_ step: AppleSyncStep) async throws {
            switch step {
            case let .createOhana(apple):
                let fields = AppleSyncMapping.ohana(apple.fields, url: apple.url, current: nil)
                let created: CalendarEventSeries = try await context.api.send(
                    .post, "/events", body: AppleImportBody(input: fields.input, externalId: apple.key))
                pass.changedOhana = true
                guard !linked.contains(created.id), !links.contains(where: { $0.ohanaID == created.id }) else { return }
                links.append(AppleSyncLink(ohanaID: created.id, appleID: apple.localID, appleKey: apple.key,
                                           ohana: OhanaSyncFields(created), apple: apple.fields))
            case let .updateOhana(id, fields, apple):
                let patched: CalendarEventSeries = try await context.api.send(
                    .patch, "/events/\(id)", body: fields.input)
                pass.changedOhana = true
                links.append(AppleSyncLink(ohanaID: patched.id, appleID: apple.localID, appleKey: apple.key,
                                           ohana: OhanaSyncFields(patched), apple: apple.fields,
                                           exceptions: AppleCalendarSync.kept(previous[id], rule: fields.rrule)))
            case let .deleteOhana(id):
                do {
                    try await context.api.perform(.delete, "/events/\(id)")
                } catch let error as APIError where error.status == 404 {}
                pass.changedOhana = true
            case let .updateOhanaOccurrence(id, day, fields):
                let _: CalendarEventSeries = try await context.api.send(
                    .patch, "/events/\(id)", query: AppleCalendarSync.occurrenceQuery(day), body: fields.input)
                pass.changedOhana = true
            case let .deleteOhanaOccurrence(id, day):
                do {
                    let _: JSONValue = try await context.api.send(.delete, "/events/\(id)",
                                                                  query: AppleCalendarSync.occurrenceQuery(day))
                } catch let error as APIError where error.status == 404 {}
                pass.changedOhana = true
            default:
                break
            }
        }

        /// A step that failed: the pass says so, and what was there before it stays.
        mutating func keepAfterFailure(_ step: AppleSyncStep, error: any Error) {
            pass.failed = error
            switch step {
            case let .updateAppleOccurrence(_, day, _, ohanaID), let .deleteAppleOccurrence(_, day, ohanaID):
                failedDays[ohanaID, default: []].insert(day)
            case let .updateOhanaOccurrence(id, day, _), let .deleteOhanaOccurrence(id, day):
                failedDays[id, default: []].insert(day)
            case let .updateApple(item, _), let .link(item, _, _):
                // A link that couldn't be brought up to date stays as it was: tried again next time.
                if let link = previous[item.id], !links.contains(where: { $0.ohanaID == item.id }) {
                    links.append(link)
                }
            case let .updateOhana(id, _, _):
                if let link = previous[id], !links.contains(where: { $0.ohanaID == id }) { links.append(link) }
            default:
                break
            }
        }
    }
}
