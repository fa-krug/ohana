import Foundation

/// Everything still to do with a family's documents as one progress: the device's uploads (text
/// read, pages sent as images) and what the server's worker hasn't finished (`working`: text
/// chunked, pages transcribed, summary written). Counted by what's left, the total being the most
/// that was left since it last came to nothing (or a total known ahead, *Read All*'s files): new
/// work beyond it adds to the total, a little more left than before moves the bar back.
nonisolated struct KnowledgeWorkProgress: Equatable, Sendable {
    private(set) var total = 0
    private(set) var remaining = 0

    var done: Int { total - remaining }
    var isActive: Bool { remaining > 0 }

    /// What's left now; `atLeast`: a total known ahead.
    mutating func update(remaining left: Int, atLeast: Int = 0) {
        remaining = max(left, 0)
        total = remaining == 0 ? 0 : max(total, remaining, atLeast)
    }
}
