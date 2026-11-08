import SwiftUI

// The assistant's memory: the family's standing instructions, by module (server
// lib/assistant/memories.ts; GET/POST /ai/memories, PATCH/DELETE /ai/memories/{id}). The assistant
// saves them itself in a chat (`remember`, `update_memory`, `forget`); editors manage them on
// Settings → Assistant → Memory.

/// What a memory is about: the family as a whole or one module.
nonisolated enum AssistantMemoryModule: Hashable, Sendable, Codable {
    case general, calendar, finance, meals, appointments, chores, knowledge
    /// A module this app doesn't know yet (a newer server's).
    case other(String)

    /// The server's order.
    static let known: [AssistantMemoryModule] = [.general, .calendar, .finance, .meals, .appointments, .chores, .knowledge]

    /// The longest memory the server takes, in characters.
    static let maxLength = 300

    init(rawValue: String) {
        self = Self.known.first { $0.rawValue == rawValue } ?? .other(rawValue)
    }

    var rawValue: String {
        switch self {
        case .general: "general"
        case .calendar: "calendar"
        case .finance: "finance"
        case .meals: "meals"
        case .appointments: "appointments"
        case .chores: "chores"
        case .knowledge: "knowledge"
        case let .other(name): name
        }
    }

    /// Where it sorts: the known ones in the server's order, others after them.
    var order: Int { Self.known.firstIndex(of: self) ?? Self.known.count }

    init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One standing instruction.
nonisolated struct AssistantMemory: Codable, Equatable, Identifiable, OffMainDecodable {
    nonisolated struct Author: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    var id: String
    var module: AssistantMemoryModule
    var text: String
    var createdAt: String
    var updatedAt: String
    /// Who saved it (null: an account since removed).
    var createdBy: Author?
}

/// GET /ai/memories.
nonisolated struct AssistantMemoryList: OffMainDecodable, Equatable {
    var memories: [AssistantMemory]

    /// The memories by module (only those with any), in the server's module order, each module's
    /// as they came (oldest first).
    var sections: [(module: AssistantMemoryModule, memories: [AssistantMemory])] {
        var modules: [AssistantMemoryModule] = []
        var byModule: [AssistantMemoryModule: [AssistantMemory]] = [:]
        for memory in memories {
            if byModule[memory.module] == nil { modules.append(memory.module) }
            byModule[memory.module, default: []].append(memory)
        }
        return modules
            .sorted { ($0.order, $0.rawValue) < ($1.order, $1.rawValue) }
            .map { ($0, byModule[$0] ?? []) }
    }

    /// How many a module has (the server takes 50 at most per module).
    func count(of module: AssistantMemoryModule) -> Int {
        memories.count { $0.module == module }
    }
}

/// POST /ai/memories, PATCH /ai/memories/{id}.
nonisolated struct AssistantMemoryInput: Encodable, Sendable {
    var module: String
    var text: String
}

@MainActor
extension AssistantMemoryModule {
    /// The app's module of it; nil for the family as a whole and unknown ones.
    var appModule: Module? {
        switch self {
        case .general, .other: nil
        case .calendar: .calendar
        case .finance: .finance
        case .meals: .meals
        case .appointments: .appointments
        case .chores: .chores
        case .knowledge: .knowledge
        }
    }

    var title: Text {
        switch self {
        case .general: Text("General")
        case let .other(name): Text(verbatim: name.capitalized)
        default: Text(appModule?.title ?? "")
        }
    }

    var systemImage: String {
        appModule?.systemImage ?? "sparkles"
    }

    var tint: Color {
        appModule?.tint ?? ModuleTint.assistant
    }
}

/// The requests of the memory page.
@MainActor
enum AssistantMemories {
    /// The list's GET (kept on the device).
    static func request(_ api: FamilyAPI) -> CachedGet<AssistantMemoryList> {
        api.cached("/ai/memories")
    }

    /// The modules a memory can be filed under: the family as a whole and the modules it has on.
    static func modules(_ family: FamilyContext) -> [AssistantMemoryModule] {
        AssistantMemoryModule.known.filter { module in
            module.appModule.map { family.isEnabled($0) } ?? true
        }
    }

    @discardableResult
    static func create(_ family: FamilyContext, module: AssistantMemoryModule, text: String) async throws -> AssistantMemory {
        let memory = try await family.api.send(.post, "/ai/memories",
                                               body: AssistantMemoryInput(module: module.rawValue, text: text),
                                               as: AssistantMemory.self)
        family.didChange(.memories)
        return memory
    }

    @discardableResult
    static func update(_ family: FamilyContext, id: String, module: AssistantMemoryModule, text: String) async throws -> AssistantMemory {
        let memory = try await family.api.send(.patch, "/ai/memories/\(id)",
                                               body: AssistantMemoryInput(module: module.rawValue, text: text),
                                               as: AssistantMemory.self)
        family.didChange(.memories)
        return memory
    }

    static func delete(_ family: FamilyContext, id: String) async throws {
        try await family.api.perform(.delete, "/ai/memories/\(id)")
        family.didChange(.memories)
    }
}
