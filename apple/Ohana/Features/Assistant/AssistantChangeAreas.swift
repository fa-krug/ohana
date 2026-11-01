import Foundation

/// Which data a change of the assistant touches (the web's components/assistant/events.ts
/// `moduleOf`), so the screens showing it reload: by the change's kind, the paths of its undo
/// steps, and the names of the tools that write.
enum AssistantChangeAreas {
    /// The areas of a change item: its kind plus what its undo requests touch.
    static func areas(change kind: String, undo: [AssistantUndoStep] = []) -> [DataArea] {
        unique(areas(kind: kind) + undo.flatMap { areas(path: $0.path) })
    }

    /// The areas a change kind names (entries | notes | types | events | categories |
    /// transactions | benchmark | recipes | plan | appointments).
    static func areas(kind: String) -> [DataArea] {
        switch kind {
        case "entries", "notes", "types": [.calendar]
        case "events": [.events, .calendar]
        case "categories", "transactions", "benchmark": [.finance]
        case "recipes": [.recipes, .meals]
        case "plan": [.mealPlan, .meals]
        case "appointments": [.appointments]
        default: []
        }
    }

    /// The areas a request on the family API touches, by its path (relative to the family).
    static func areas(path: String) -> [DataArea] {
        let clean = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = clean.split(separator: "/").map(String.init)
        guard let first = parts.first else { return [] }
        switch first {
        case "entries", "notes", "types": return [.calendar]
        case "events": return [.events, .calendar]
        case "finance": return [.finance]
        case "appointments": return [.appointments]
        case "recipes": return [.recipes, .meals]
        case "meals":
            switch parts.dropFirst().first {
            case "recipes": return [.recipes, .meals]
            case "plan": return [.mealPlan, .meals]
            default: return [.meals]
            }
        default: return []
        }
    }

    /// The areas a tool changes when it runs (empty for the tools that only read). Most writes
    /// also come as a change item; this covers the ones that don't (starting a search).
    static func areas(tool name: String) -> [DataArea] {
        switch name {
        case "change_entries", "set_notes", "manage_entry_types": [.calendar]
        case "add_event", "remove_event": [.events, .calendar]
        case "manage_categories", "change_transactions", "combine_transfers", "set_statistic_average": [.finance]
        case "save_recipe": [.recipes, .meals]
        case "plan_meals": [.mealPlan, .meals]
        case "create_appointment_search", "change_appointment_search", "run_appointment_search": [.appointments]
        case "book_appointment_slot": [.appointments, .events, .calendar]
        default: []
        }
    }

    static func unique(_ areas: [DataArea]) -> [DataArea] {
        var seen = Set<DataArea>()
        return areas.filter { seen.insert($0).inserted }
    }
}
