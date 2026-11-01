import Foundation
import Testing
@testable import Ohana

/// Deleting a recipe waits a moment so it can be undone (`MealsPendingDeletes`).
@MainActor
struct MealsPendingDeletesTests {
    /// What the delete sent and whether it finished.
    final class Log {
        var sent: [String] = []
        var done = 0
    }

    func deletes() -> MealsPendingDeletes {
        let deletes = MealsPendingDeletes()
        deletes.delay = .milliseconds(20)
        return deletes
    }

    func schedule(_ deletes: MealsPendingDeletes, _ id: String, _ log: Log, undoManager: UndoManager? = nil) {
        deletes.schedule(id, kind: .recipe, title: "Tomato soup", undoManager: undoManager) {
            log.sent.append(id)
        } done: {
            log.done += 1
        }
    }

    /// Waits until `condition` holds (at most two seconds).
    func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func hidesAtOnceAndDeletesAfterAMoment() async throws {
        let deletes = deletes(), log = Log()
        schedule(deletes, "i1", log)
        #expect(deletes.isHidden("i1"))
        #expect(deletes.latest == .init(id: "i1", title: "Tomato soup", kind: .recipe))
        #expect(log.sent.isEmpty)
        try await until { log.done == 1 }
        #expect(log.sent == ["i1"])
        #expect(!deletes.isHidden("i1"))
        #expect(deletes.latest == nil)
    }

    @Test func undoKeepsIt() async throws {
        let deletes = deletes(), log = Log()
        deletes.delay = .milliseconds(50)
        schedule(deletes, "i1", log)
        deletes.undo("i1")
        #expect(!deletes.isHidden("i1"))
        #expect(deletes.latest == nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(log.sent.isEmpty && log.done == 0)
    }

    @Test func theUndoManagerTakesItBackUntilItIsDone() async throws {
        let deletes = deletes(), log = Log(), manager = UndoManager()
        // No run loop opens the undo groups here.
        manager.groupsByEvent = false
        deletes.delay = .seconds(60)
        manager.beginUndoGrouping()
        schedule(deletes, "i1", log, undoManager: manager)
        manager.endUndoGrouping()
        #expect(manager.canUndo)
        #expect(manager.undoActionName == String(localized: "Delete Recipe"))
        manager.undo()
        #expect(!deletes.isHidden("i1"))

        deletes.delay = .milliseconds(20)
        manager.beginUndoGrouping()
        schedule(deletes, "i2", log, undoManager: manager)
        manager.endUndoGrouping()
        try await until { log.done == 1 }
        #expect(log.sent == ["i2"])
        #expect(!manager.canUndo) // gone with the delete
    }

    @Test func deletesFromTheRightPath() {
        #expect(MealsPendingDeletes.Kind.recipe.path("r1") == "/meals/recipes/r1")
        #expect(MealsPendingDeletes.Kind.recipe.areas == [.recipes, .meals, .mealPlan])
    }
}
