import Foundation
import Testing
@testable import Ohana

/// The cook view's timers: the durations found in a step's text, and the timers they start.
struct StepDurationTests {
    /// The durations of `text` as (matched text, seconds).
    private func found(_ text: String) -> [(String, Int)] {
        StepDurations.find(in: text).map { (String(text[$0.range]), $0.seconds) }
    }

    @Test func findsEnglishDurations() {
        let result = found("Simmer for 20 minutes, then rest 30 sec. Bake 1 hr.")
        #expect(result.map(\.0) == ["20 minutes", "30 sec", "1 hr"])
        #expect(result.map(\.1) == [1200, 30, 3600])
    }

    @Test func findsGermanDurations() {
        let result = found("20 Min. köcheln lassen, dann 2 Stunden ruhen und 10 Sekunden mixen.")
        #expect(result.map(\.0) == ["20 Min", "2 Stunden", "10 Sekunden"])
        #expect(result.map(\.1) == [1200, 7200, 10])
    }

    @Test func rangesCountFromTheirLowerEnd() {
        #expect(found("Bake 25–30 minutes").map(\.1) == [1500])
        #expect(found("Bake 25-30 min").map(\.0) == ["25-30 min"])
        #expect(found("5 to 6 minutes").map(\.1) == [300])
        #expect(found("5 bis 6 Minuten").map(\.1) == [300])
    }

    @Test func fractionsAndWords() {
        #expect(found("Cook 1½ hours").map(\.1) == [5400])
        #expect(found("Cook 1 1/2 hours").map(\.1) == [5400])
        #expect(found("Cook 1,5 Std").map(\.1) == [5400])
        #expect(found("Stir for a minute").map(\.1) == [60])
        #expect(found("Wait half an hour").map(\.1) == [1800])
        #expect(found("Cook two and a half hours").map(\.1) == [9000])
        #expect(found("Eine halbe Stunde ziehen lassen").map(\.0) == ["Eine halbe Stunde"])
        #expect(found("Nach einer halben Stunde wenden").map(\.1) == [1800])
        #expect(found("Anderthalb Stunden schmoren").map(\.1) == [5400])
        #expect(found("Fünf Minuten rühren").map(\.1) == [300])
    }

    @Test func compoundsAddUp() {
        #expect(found("Roast 1 hour 30 minutes").map(\.1) == [5400])
        #expect(found("1 Std. 20 Min. backen").map(\.0) == ["1 Std. 20 Min"])
        #expect(found("1 hour and 15 minutes").map(\.1) == [4500])
        #expect(found("1 Stunde und 10 Minuten").map(\.1) == [4200])
        // Not a compound: separate steps.
        #expect(found("Cook 5 minutes, then wait 30 seconds").map(\.1) == [300, 30])
        // A larger unit after a smaller one stays separate.
        #expect(found("10 minutes 1 hour").map(\.1) == [600, 3600])
    }

    @Test func hyphenatedAdjectives() {
        #expect(found("Let it have a 10-minute rest").map(\.0) == ["10-minute"])
    }

    @Test func ignoresWhatIsNotADuration() {
        #expect(found("Add 200 g flour and 2 eggs").isEmpty)
        #expect(found("Season to taste, minimum 2 pinches").isEmpty)
        #expect(found("Heat to 180 °C").isEmpty)
        #expect(found("The man said hello").isEmpty)
        #expect(found("Marinate 0 minutes").isEmpty)
        #expect(found("Age 100 hours").isEmpty)
        #expect(found("in 3h").map(\.1) == [10800])
        #expect(found("Mixed3 minutes").isEmpty)
    }

    @Test func linksEachDuration() throws {
        let text = "Simmer 20 minutes, rest 5 min."
        let durations = StepDurations.find(in: text)
        let linked = StepDurations.linked(text, durations: durations)
        #expect(String(linked.characters) == text)
        let links = linked.runs.compactMap { run in run.link.map { (String(linked[run.range].characters), $0) } }
        #expect(links.map(\.0) == ["20 minutes", "5 min"])
        #expect(links.map { StepDurations.index(of: $0.1) } == [0, 1])
        #expect(StepDurations.index(of: try #require(URL(string: "https://example.com/1"))) == nil)
    }
}

struct CookTimerStoreTests {
    private func store() -> (CookTimers, UserDefaults) {
        let defaults = UserDefaults(suiteName: "cook-timers-\(UUID().uuidString)")!
        return (CookTimers(defaults: defaults, effects: false), defaults)
    }

    @discardableResult
    private func start(_ timers: CookTimers, source: String = "r1/1/0", seconds: Int = 600, at date: Date = .now) -> CookTimer {
        timers.start(source: source, recipeID: "r1", recipeTitle: "Soup", stepID: 1, stepLabel: "Step 1",
                     instruction: "Simmer 10 minutes", seconds: seconds, at: date)
    }

    @Test func theSameDurationRunsOnce() {
        let (timers, _) = store()
        let first = start(timers)
        let again = start(timers)
        #expect(first.id == again.id)
        #expect(timers.timers.count == 1)
        start(timers, source: "r1/1/1")
        #expect(timers.timers.count == 2)
    }

    @Test func aFinishedTimerMakesRoomForANewOne() {
        let (timers, _) = store()
        let old = start(timers, at: .now.addingTimeInterval(-700))
        #expect(old.isDone(at: .now))
        let new = start(timers)
        #expect(new.id != old.id)
        #expect(timers.timers.map(\.id) == [new.id])
    }

    @Test func sortedSoonestFirstAndRemoved() {
        let (timers, _) = store()
        let long = start(timers, source: "a", seconds: 900)
        let short = start(timers, source: "b", seconds: 60)
        #expect(timers.sorted.map(\.id) == [short.id, long.id])
        timers.remove(short.id)
        #expect(timers.timers.map(\.id) == [long.id])
    }

    @Test func keptAcrossLaunchesUntilAnHourAfterTheyFinish() {
        let (timers, defaults) = store()
        let running = start(timers, source: "a")
        start(timers, source: "b", seconds: 60, at: .now.addingTimeInterval(-3700))
        let finished = start(timers, source: "c", seconds: 60, at: .now.addingTimeInterval(-120))
        let reopened = CookTimers(defaults: defaults, effects: false)
        #expect(Set(reopened.timers.map(\.id)) == [running.id, finished.id])
    }
}
