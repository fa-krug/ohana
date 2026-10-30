import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// Small pieces the recipe screens share.

extension RecipeTag {
    /// The web's badge colours per category.
    var color: Color { RecipeTagCategory(rawValue: category)?.color ?? .gray }
}

extension RecipeTagCategory {
    var color: Color {
        switch self {
        case .dietary: .green
        case .protein: .red
        case .cuisine: .blue
        case .mealType: .orange
        }
    }
}

/// A tag as a small tinted capsule.
struct RecipeTagChip: View {
    let tag: RecipeTag
    var selected = true

    var body: some View {
        Text(tag.name)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(selected ? tag.color : .secondary)
            .background((selected ? tag.color : Color.secondary).opacity(0.15), in: .capsule)
    }
}

/// Tags that can be switched on and off, grouped by category (filter, editor, generator).
struct RecipeTagPicker: View {
    let tags: [RecipeTag]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 6) {
                    Text(group.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    RecipeFlowLayout(spacing: 6) {
                        ForEach(group.tags) { tag in
                            let on = selection.contains(tag.id)
                            Button {
                                if on { selection.remove(tag.id) } else { selection.insert(tag.id) }
                            } label: {
                                Label(tag.name, systemImage: on ? "checkmark" : "plus")
                                    .labelStyle(RecipeChipLabelStyle(showsIcon: on))
                                    .font(.subheadline)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .foregroundStyle(on ? Color.white : .primary)
                                    .background(on ? AnyShapeStyle(tag.color.gradient) : AnyShapeStyle(.quaternary), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
        }
    }

    private var groups: [(title: String, tags: [RecipeTag])] {
        var out: [(String, [RecipeTag])] = RecipeTagCategory.allCases.compactMap { cat in
            let inCat = tags.filter { $0.category == cat.rawValue }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            return inCat.isEmpty ? nil : (String(localized: cat.title), inCat)
        }
        let custom = tags.filter { RecipeTagCategory(rawValue: $0.category) == nil }
        if !custom.isEmpty { out.append((String(localized: "Custom"), custom)) }
        return out
    }
}

private struct RecipeChipLabelStyle: LabelStyle {
    let showsIcon: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            if showsIcon { configuration.icon.imageScale(.small) }
            configuration.title
        }
    }
}

/// Lays its children out in rows, wrapping like text (tags, chips).
struct RecipeFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// Prep time, cooking time and servings, as small labels.
struct RecipeMetaRow: View {
    let prep: Int?
    let cook: Int?
    let servings: Int

    var body: some View {
        // The words where they fit (the recipe page), only the numbers on a narrow card.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                if let prep { Label("Prep \(prep) min", systemImage: "timer") }
                if let cook { Label("Cooking \(cook) min", systemImage: "flame") }
                Label("\(servings) servings", systemImage: "person.2")
            }
            HStack(spacing: 10) {
                if let prep { Label("\(prep) min", systemImage: "timer") }
                if let cook { Label("\(cook) min", systemImage: "flame") }
                Label(String(servings), systemImage: "person.2")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
    }
}

/// A machine step's settings (the web's StepParams).
struct RecipeStepParams: View {
    let step: RecipeStep

    var body: some View {
        let parts = Self.parts(step)
        if !parts.isEmpty {
            RecipeFlowLayout(spacing: 6) {
                ForEach(parts, id: \.self) { part in
                    Text(part)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: .capsule)
                }
            }
        }
    }

    static func parts(_ step: RecipeStep) -> [String] {
        var out: [String] = []
        if let t = step.temperature { out.append(String(localized: "\(t) °C")) }
        if let d = step.durationSeconds { out.append(RecipeDuration.format(d)) }
        if let s = step.speed { out.append(String(localized: "Speed \(s)")) }
        if step.direction == "LEFT" { out.append(String(localized: "Left")) }
        if step.direction == "RIGHT" { out.append(String(localized: "Right")) }
        if let w = step.weightGrams { out.append(String(localized: "\(w) g")) }
        if step.turbo { out.append(String(localized: "Turbo")) }
        return out
    }
}

/// A placeholder where a recipe has no photo.
struct RecipePhotoPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [ModuleTint.meals.opacity(0.35), ModuleTint.meals.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "fork.knife")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: Shared lists, cached

/// The shared ingredients and units (the same for every family), loaded once per session.
enum RecipeCatalogCache {
    private static var cached: (server: String, catalog: RecipeCatalog)?

    static func load(_ api: FamilyAPI, refresh: Bool = false) async throws -> RecipeCatalog {
        let server = api.client.baseURL.absoluteString
        if !refresh, let cached, cached.server == server { return cached.catalog }
        let catalog: RecipeCatalog = try await api.get("/meals/catalog")
        cached = (server, catalog)
        return catalog
    }
}

// MARK: Photos

enum RecipePhotoEncoding {
    /// A photo as JPEG of at most 2048 px on its longest side (the server takes JPEG, PNG and
    /// WebP up to 5 MB; HEIC from the camera roll is converted here).
    static func jpeg(from data: Data, maxPixels: Int = 2048) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

extension FamilyAPI {
    /// PUT /meals/recipes/{id}/image with the photo's bytes.
    func uploadRecipePhoto(_ recipeID: String, data: Data) async throws {
        guard let jpeg = RecipePhotoEncoding.jpeg(from: data) else {
            throw APIError.http(status: 400, message: String(localized: "That file isn’t a picture."))
        }
        var req = client.request(.put, path("/meals/recipes/\(recipeID)/image"), body: jpeg, contentType: "image/jpeg")
        req.timeoutInterval = 120
        _ = try await client.data(for: req)
    }
}

extension View {
    /// A sheet sized for the Mac (sheets there take their content's size).
    func recipeSheetFrame(minWidth: CGFloat = 520, minHeight: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: minWidth + 80, minHeight: minHeight, idealHeight: minHeight + 120)
        #else
        self
        #endif
    }
}
