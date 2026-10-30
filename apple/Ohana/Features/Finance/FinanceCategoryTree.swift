import Foundation

/// The categories as a tree, any depth (web/components/finance/category-tree.ts). Siblings go by
/// position, then name; a parent that doesn't exist (or a loop) counts as top level.
struct FinanceCategoryTree {
    struct Node: Hashable, Identifiable {
        var category: FinanceCategory
        /// 0 for a top-level category.
        var depth: Int
        var children: [String]

        var id: String { category.id }
    }

    static let separator = " › "

    /// Every category after its parent, siblings in order (depth first).
    let ordered: [Node]
    let roots: [String]
    private let nodes: [String: Node]
    private let parents: [String: String]

    init(_ categories: [FinanceCategory]) {
        let known = Set(categories.map(\.id))
        let sorted = categories.sorted {
            $0.position != $1.position ? $0.position < $1.position
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        var kids: [String?: [FinanceCategory]] = [:]
        for c in sorted {
            let parent = c.parentId.flatMap { known.contains($0) ? $0 : nil }
            kids[parent, default: []].append(c)
        }
        var nodes: [String: Node] = [:]
        var parents: [String: String] = [:]
        var ordered: [Node] = []
        var roots: [String] = []

        func visit(_ c: FinanceCategory, parent: String?, depth: Int) -> Bool {
            if nodes[c.id] != nil { return false }
            nodes[c.id] = Node(category: c, depth: depth, children: [])
            if let parent { parents[c.id] = parent }
            let index = ordered.count
            ordered.append(nodes[c.id]!)
            var children: [String] = []
            for k in kids[c.id] ?? [] where visit(k, parent: c.id, depth: depth + 1) {
                children.append(k.id)
            }
            nodes[c.id]!.children = children
            ordered[index].children = children
            return true
        }
        // In a loop: the first one becomes top level.
        for c in (kids[nil] ?? []) + sorted where visit(c, parent: nil, depth: 0) {
            roots.append(c.id)
        }
        self.ordered = ordered
        self.roots = roots
        self.nodes = nodes
        self.parents = parents
    }

    var isEmpty: Bool { ordered.isEmpty }

    func node(_ id: String?) -> Node? { id.flatMap { nodes[$0] } }
    func category(_ id: String?) -> FinanceCategory? { node(id)?.category }
    func parent(of id: String) -> FinanceCategory? { parents[id].flatMap { nodes[$0]?.category } }
    func children(of id: String?) -> [Node] {
        (id.map { nodes[$0]?.children ?? [] } ?? roots).compactMap { nodes[$0] }
    }

    /// "Food › Groceries".
    func path(_ id: String) -> String {
        var names: [String] = []
        var current = nodes[id]?.category
        while let c = current {
            names.insert(c.name, at: 0)
            current = parent(of: c.id)
        }
        return names.joined(separator: Self.separator)
    }

    /// The category's id and those of all its descendants.
    func subtree(_ id: String) -> Set<String> {
        var out: Set<String> = []
        func add(_ id: String) {
            guard let node = nodes[id] else { return }
            out.insert(id)
            node.children.forEach(add)
        }
        add(id)
        return out
    }

    /// The top-level category of a category ("" for none, or one that is gone).
    func top(of id: String?) -> String {
        guard var current = id, nodes[current] != nil else { return "" }
        while let p = parents[current] { current = p }
        return current
    }

    /// The kind a transaction of this sign fits (both, or the matching one).
    static func fits(_ category: FinanceCategory, income: Bool) -> Bool {
        category.kind == .both || (category.kind == .income) == income
    }

    /// Where a category can move: anywhere but into itself or one of its subcategories.
    func moveTargets(for id: String) -> [Node] {
        let inside = subtree(id)
        return ordered.filter { !inside.contains($0.id) }
    }

    /// The siblings' new positions after moving `id` one step up (-1) or down (1): only those
    /// that change, as (id, position); empty at the edge.
    func reorder(_ id: String, by step: Int) -> [(String, Int)] {
        var siblings = children(of: parents[id]).map(\.category)
        guard let i = siblings.firstIndex(where: { $0.id == id }) else { return [] }
        let j = i + step
        guard siblings.indices.contains(j) else { return [] }
        siblings.swapAt(i, j)
        // Siblings get the positions 0, 1, 2 …: only those that change are saved.
        return siblings.enumerated().compactMap { position, c in
            c.position == position ? nil : (c.id, position)
        }
    }
}
