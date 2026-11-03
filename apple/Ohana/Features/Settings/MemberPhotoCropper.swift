import CoreGraphics
import PhotosUI
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Where a member's picture is cut from its original (server/lib/families/photos.ts): fractions of
/// the upright original, `x`, `y` its top-left corner, `w`, `h` its size. The app always sends a
/// square in pixels (`w · width == h · height`).
nonisolated struct MemberPhotoCrop: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    /// Rounded down to six decimals (enough for any original) and kept inside the image, so the
    /// server's `x + w ≤ 1` holds after the rounding too.
    func rounded() -> MemberPhotoCrop {
        func down(_ v: Double) -> Double { (v * 1_000_000).rounded(.down) / 1_000_000 }
        var w = min(1, max(down(w), 0.000_001)), h = min(1, max(down(h), 0.000_001))
        var x = max(0, down(x)), y = max(0, down(y))
        if x + w > 1 { x = max(0, x - 0.000_001); if x + w > 1 { w = 1 - x } }
        if y + h > 1 { y = max(0, y - 0.000_001); if y + h > 1 { h = 1 - y } }
        return MemberPhotoCrop(x: x, y: y, w: w, h: h)
    }

    /// The query of a photo upload (`PUT …/photo?x=&y=&w=&h=`): plain decimals with a point.
    var query: [String: String?] {
        let c = rounded()
        func text(_ v: Double) -> String { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), v) }
        return ["x": text(c.x), "y": text(c.y), "w": text(c.w), "h": text(c.h)]
    }
}

/// The body of `PATCH …/photo`: a new crop of the stored original.
nonisolated struct MemberPhotoCropInput: Encodable {
    let crop: MemberPhotoCrop
}

/// The crop editor's math, pure. The editor shows the image under a round viewport of side
/// `viewport`; `zoom` 1 is the smallest scale at which the image covers it, `offset` how far the
/// image's centre is moved from the viewport's (points of the viewport, y down).
nonisolated struct MemberPhotoCropGeometry: Equatable {
    /// The image's size in pixels.
    let width: CGFloat
    let height: CGFloat

    /// The smallest square (pixels of the original) the zoom may come down to.
    static let minCropPixels: CGFloat = 160

    init(width: CGFloat, height: CGFloat) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }

    init(image: CGImage) {
        self.init(width: CGFloat(image.width), height: CGFloat(image.height))
    }

    var shortSide: CGFloat { min(width, height) }

    /// The closest zoom: the crop stays at least `minCropPixels` (1 for a smaller image).
    var maxZoom: CGFloat { max(1, shortSide / Self.minCropPixels) }

    func clampZoom(_ zoom: CGFloat) -> CGFloat { min(max(zoom, 1), maxZoom) }

    /// Points of the viewport per pixel of the image.
    func scale(zoom: CGFloat, viewport: CGFloat) -> CGFloat { viewport / shortSide * zoom }

    /// The image's size on screen.
    func displaySize(zoom: CGFloat, viewport: CGFloat) -> CGSize {
        let s = scale(zoom: zoom, viewport: viewport)
        return CGSize(width: width * s, height: height * s)
    }

    /// How far the image may move each way and still cover the viewport.
    func offsetLimit(zoom: CGFloat, viewport: CGFloat) -> CGSize {
        let size = displaySize(zoom: zoom, viewport: viewport)
        return CGSize(width: max(0, (size.width - viewport) / 2), height: max(0, (size.height - viewport) / 2))
    }

    func clamp(_ offset: CGSize, zoom: CGFloat, viewport: CGFloat) -> CGSize {
        let limit = offsetLimit(zoom: zoom, viewport: viewport)
        return CGSize(width: min(max(offset.width, -limit.width), limit.width),
                      height: min(max(offset.height, -limit.height), limit.height))
    }

    /// The offset after zooming from `from` to `to` around `anchor` (a point of the viewport,
    /// relative to its centre): the image's point under the anchor stays there.
    static func zoomed(_ offset: CGSize, from: CGFloat, to: CGFloat, anchor: CGPoint) -> CGSize {
        let f = to / from
        return CGSize(width: anchor.x - (anchor.x - offset.width) * f,
                      height: anchor.y - (anchor.y - offset.height) * f)
    }

    /// `value` inside `lower…upper` as is; past a limit it moves on with growing resistance, never
    /// more than `dimension` beyond it (UIScrollView's rubber band).
    static func rubberBand(_ value: CGFloat, lower: CGFloat, upper: CGFloat, dimension: CGFloat) -> CGFloat {
        func band(_ excess: CGFloat) -> CGFloat {
            guard dimension > 0 else { return 0 }
            return (1 - 1 / (excess * 0.55 / dimension + 1)) * dimension
        }
        if value < lower { return lower - band(lower - value) }
        if value > upper { return upper + band(value - upper) }
        return value
    }

    /// The zoom during a pinch: a little past the limits, with resistance.
    func rubberBandZoom(_ zoom: CGFloat) -> CGFloat {
        Self.rubberBand(zoom, lower: 1, upper: maxZoom, dimension: 0.5)
    }

    /// The offset during a drag: a little past the edges, with resistance.
    func rubberBand(_ offset: CGSize, zoom: CGFloat, viewport: CGFloat) -> CGSize {
        let limit = offsetLimit(zoom: zoom, viewport: viewport)
        let d = viewport / 2
        return CGSize(width: Self.rubberBand(offset.width, lower: -limit.width, upper: limit.width, dimension: d),
                      height: Self.rubberBand(offset.height, lower: -limit.height, upper: limit.height, dimension: d))
    }

    /// Where a gesture comes to rest: the zoom back within its limits (around `anchor`), the
    /// image covering the viewport.
    func settled(zoom: CGFloat, offset: CGSize, anchor: CGPoint, viewport: CGFloat) -> (zoom: CGFloat, offset: CGSize) {
        let z = clampZoom(zoom)
        let o = Self.zoomed(offset, from: zoom, to: z, anchor: anchor)
        return (z, clamp(o, zoom: z, viewport: viewport))
    }

    /// The part of the image inside the viewport, as fractions of the image (zoom and offset
    /// clamped first).
    func crop(zoom: CGFloat, offset: CGSize, viewport: CGFloat) -> MemberPhotoCrop {
        let z = clampZoom(zoom)
        let o = clamp(offset, zoom: z, viewport: viewport)
        let s = scale(zoom: z, viewport: viewport)
        let side = shortSide / z
        let left = width / 2 - (viewport / 2 + o.width) / s
        let top = height / 2 - (viewport / 2 + o.height) / s
        let w = min(1, side / width), h = min(1, side / height)
        return MemberPhotoCrop(x: Double(min(max(0, left / width), 1 - w)),
                               y: Double(min(max(0, top / height), 1 - h)),
                               w: Double(w), h: Double(h))
    }

    /// The zoom and offset that show `crop` (nil: the centred cover), clamped.
    func placement(of crop: MemberPhotoCrop?, viewport: CGFloat) -> (zoom: CGFloat, offset: CGSize) {
        guard let crop, crop.w > 0, crop.h > 0 else { return (1, .zero) }
        let side = (CGFloat(crop.w) * width + CGFloat(crop.h) * height) / 2
        let z = clampZoom(shortSide / side)
        let s = scale(zoom: z, viewport: viewport)
        let cx = (CGFloat(crop.x) + CGFloat(crop.w) / 2) * width
        let cy = (CGFloat(crop.y) + CGFloat(crop.h) / 2) * height
        let o = CGSize(width: (width / 2 - cx) * s, height: (height / 2 - cy) * s)
        return (z, clamp(o, zoom: z, viewport: viewport))
    }
}

/// The member photo's editor, "Move and Scale" as in Contacts: the picture under a round
/// cut-out, the rest dimmed. Pinch to zoom (around the fingers) and drag to move, both at once, a
/// little past the limits until the gesture ends; double-tap zooms in around the tap, or back out
/// to the whole. On the Mac also two-finger scrolling (moves) and the mouse wheel or ⌘-scroll
/// (zooms around the pointer). VoiceOver adjusts the zoom and has actions to move.
/// Below the picture: another one from the library or a file (centred again), and removing the
/// stored photo. Save hands the picture and its crop back and closes; for the stored photo it
/// waits for a change. Cancel never asks.
struct MemberPhotoCropper: View {
    /// The picture it opens with.
    let photo: PreparedMemberPhoto
    let initial: MemberPhotoCrop?
    /// The picture is the member's current photo: Save waits for a change.
    var stored = false
    /// Whose photo it is (the removal's question).
    let name: String
    /// The member has a photo to remove.
    var canRemove = false
    let save: (PreparedMemberPhoto, MemberPhotoCrop) -> Void
    var remove: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    /// A picture chosen here instead of `photo`.
    @State private var replaced: PreparedMemberPhoto?
    /// The current zoom (1: the image just covers the viewport).
    @State private var zoom: CGFloat = 1
    /// The image centre's distance from the viewport's, in viewport sides (so it survives a
    /// resize).
    @State private var offset: CGSize = .zero
    @State private var placed = false
    /// The crop as the editor opened: the stored photo's Save waits for a change.
    @State private var start: MemberPhotoCrop?
    @State private var session: Session?
    @GestureState private var gestureActive = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var picking = false
    @State private var importing = false
    @State private var loading = false
    @State private var confirmingRemoval = false
    #if os(macOS)
    @State private var hover: CGPoint?
    @State private var scrollMonitor: Any?
    #endif

    /// A pinch / drag in progress: where it started and what it did last (one of the two may end
    /// before the other).
    private struct Session {
        let zoom: CGFloat
        let offset: CGSize
        var magnification: CGFloat = 1
        /// The pinch's start, relative to the viewport's centre, in viewport sides.
        var anchor: CGPoint = .zero
        var translation: CGSize = .zero
    }

    private var shown: PreparedMemberPhoto { replaced ?? photo }
    private var image: CGImage { shown.image }
    private var geometry: MemberPhotoCropGeometry { MemberPhotoCropGeometry(image: image) }
    private var canSave: Bool { !stored || replaced != nil || current != start }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { proxy in
                    let side = max(1, min(proxy.size.width, proxy.size.height) - 32)
                    viewport(side: side, size: proxy.size)
                }
                .overlay {
                    if loading { ProgressView().controlSize(.large) }
                }
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                actions
            }
            .background(Color.black.opacity(0.92).ignoresSafeArea())
            .environment(\.colorScheme, .dark)
            .navigationTitle("Move and Scale")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(shown, current)
                        dismiss()
                    }
                    .disabled(!canSave || loading)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 600, idealHeight: 680)
        #endif
        .onAppear {
            guard !placed else { return }
            placed = true
            (zoom, offset) = geometry.placement(of: initial, viewport: 1)
            start = current
        }
        .photosPicker(isPresented: $picking, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            replace { try await item.loadTransferable(type: Data.self) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            replace { data }
        }
        .confirmationDialog(Text("Remove the photo of \(name)?"), isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                remove()
                dismiss()
            }
        }
    }

    /// Another picture, removing the stored one.
    private var actions: some View {
        HStack(spacing: 8) {
            action("Choose Photo", systemImage: "photo.on.rectangle") { picking = true }
            action("Choose File", systemImage: "folder") { importing = true }
            if canRemove {
                action("Remove Photo", systemImage: "trash", role: .destructive) { confirmingRemoval = true }
            }
        }
        .disabled(loading)
        .padding(.horizontal)
        .padding(.bottom, 12)
    }

    private func action(_ title: LocalizedStringKey, systemImage: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }

    /// Decodes a picked picture off the main thread and shows it instead, centred.
    private func replace(_ load: @escaping () async throws -> Data?) {
        loading = true
        perform {
            defer { loading = false }
            guard let data = try await load() else { return }
            guard let photo = await Task.detached(operation: { MemberPhoto.prepare(from: data) }).value else {
                throw APIError.http(status: 400, message: String(localized: "That file isn’t a picture."))
            }
            replaced = photo
            session = nil
            (zoom, offset) = (1, .zero)
        }
    }

    /// The crop as it is shown now.
    private var current: MemberPhotoCrop {
        geometry.crop(zoom: zoom, offset: offset, viewport: 1).rounded()
    }

    private var hint: LocalizedStringKey {
        #if os(macOS)
        "Pinch or scroll to zoom, drag to move"
        #else
        "Pinch to zoom, drag to move"
        #endif
    }

    // MARK: The viewport

    private func viewport(side: CGFloat, size: CGSize) -> some View {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        return accessible(scrolling(picture(side: side, size: size, centre: centre), side: side, centre: centre))
    }

    private func picture(side: CGFloat, size: CGSize, centre: CGPoint) -> some View {
        let displayed = geometry.displaySize(zoom: zoom, viewport: side)
        return ZStack {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: displayed.width, height: displayed.height)
                .position(x: centre.x + offset.width * side, y: centre.y + offset.height * side)
            cutout(side: side, size: size)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(.rect)
        .gesture(pinchAndDrag(side: side, centre: centre))
        // A cancelled gesture doesn't end: it settles when its state resets.
        .onChange(of: gestureActive) { if !gestureActive { settle() } }
        .onTapGesture(count: 2) { location in
            doubleTap(at: point(location, centre: centre, side: side))
        }
    }

    /// The Mac's scrolling over the picture (`installScrollMonitor`).
    private func scrolling(_ content: some View, side: CGFloat, centre: CGPoint) -> some View {
        #if os(macOS)
        content
        .onContinuousHover { phase in
            switch phase {
            case let .active(location): hover = point(location, centre: centre, side: side)
            case .ended: hover = nil
            }
        }
        .onAppear { installScrollMonitor(side: side) }
        .onChange(of: side) { removeScrollMonitor(); installScrollMonitor(side: side) }
        .onDisappear { removeScrollMonitor() }
        #else
        content
        #endif
    }

    /// One element for VoiceOver: adjusting zooms, actions move.
    private func accessible(_ content: some View) -> some View {
        content
        .accessibilityElement()
        .accessibilityLabel("Photo preview")
        .accessibilityValue(Double(zoom).formatted(.percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: changeZoom(by: 1.25, around: .zero)
            case .decrement: changeZoom(by: 1 / 1.25, around: .zero)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Move Up") { move(by: CGSize(width: 0, height: -0.1)) }
        .accessibilityAction(named: "Move Down") { move(by: CGSize(width: 0, height: 0.1)) }
        .accessibilityAction(named: "Move Left") { move(by: CGSize(width: -0.1, height: 0)) }
        .accessibilityAction(named: "Move Right") { move(by: CGSize(width: 0.1, height: 0)) }
    }

    /// The dimmed surroundings of the round cut-out, and its rim.
    private func cutout(side: CGFloat, size: CGSize) -> some View {
        let circle = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
        return ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addEllipse(in: circle)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
            Path { $0.addEllipse(in: circle) }
                .stroke(Color.white.opacity(0.7), lineWidth: 1)
        }
    }

    /// A location in the view as a point relative to the viewport's centre, in viewport sides.
    private func point(_ location: CGPoint, centre: CGPoint, side: CGFloat) -> CGPoint {
        CGPoint(x: (location.x - centre.x) / side, y: (location.y - centre.y) / side)
    }

    // MARK: Gestures

    private func pinchAndDrag(side: CGFloat, centre: CGPoint) -> some Gesture {
        MagnifyGesture()
            .simultaneously(with: DragGesture(minimumDistance: 1))
            .updating($gestureActive) { _, active, _ in active = true }
            .onChanged { value in
                var state = session ?? Session(zoom: zoom, offset: offset)
                if let pinch = value.first {
                    if session == nil || state.magnification == 1 {
                        state.anchor = point(pinch.startLocation, centre: centre, side: side)
                    }
                    state.magnification = pinch.magnification
                }
                if let drag = value.second {
                    state.translation = CGSize(width: drag.translation.width / side,
                                               height: drag.translation.height / side)
                }
                session = state
                let z = geometry.rubberBandZoom(state.zoom * state.magnification)
                var o = MemberPhotoCropGeometry.zoomed(state.offset, from: state.zoom, to: z, anchor: state.anchor)
                o.width += state.translation.width
                o.height += state.translation.height
                zoom = z
                offset = geometry.rubberBand(o, zoom: z, viewport: 1)
            }
            .onEnded { _ in settle() }
    }

    /// Animates the end of a gesture back within the limits.
    private func settle() {
        guard let current = session else { return }
        session = nil
        let rest = geometry.settled(zoom: zoom, offset: offset, anchor: current.anchor, viewport: 1)
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            (zoom, offset) = rest
        }
    }

    /// Zoomed out: 2× around the tap; zoomed in: back to the whole, centred.
    private func doubleTap(at anchor: CGPoint) {
        withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
            if zoom > 1.01 {
                (zoom, offset) = (1, .zero)
            } else {
                let z = geometry.clampZoom(zoom * 2)
                let o = MemberPhotoCropGeometry.zoomed(offset, from: zoom, to: z, anchor: anchor)
                (zoom, offset) = (z, geometry.clamp(o, zoom: z, viewport: 1))
            }
        }
    }

    private func changeZoom(by factor: CGFloat, around anchor: CGPoint, animated: Bool = true) {
        let z = geometry.clampZoom(zoom * factor)
        let o = MemberPhotoCropGeometry.zoomed(offset, from: zoom, to: z, anchor: anchor)
        let apply = { (zoom, offset) = (z, geometry.clamp(o, zoom: z, viewport: 1)) }
        if animated { withAnimation(.snappy, apply) } else { apply() }
    }

    private func move(by delta: CGSize, animated: Bool = true) {
        let o = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        let apply = { offset = geometry.clamp(o, zoom: zoom, viewport: 1) }
        if animated { withAnimation(.snappy, apply) } else { apply() }
    }

    // MARK: Scrolling (Mac)

    #if os(macOS)
    /// Over the picture: two-finger scrolling moves it; a mouse wheel, or scrolling with ⌘, zooms
    /// around the pointer.
    private func installScrollMonitor(side: CGFloat) {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let anchor = hover, session == nil else { return event }
            let zooms = event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas
            if zooms {
                let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1)
                guard delta != 0 else { return nil }
                changeZoom(by: exp(delta), around: anchor, animated: false)
            } else {
                move(by: CGSize(width: event.scrollingDeltaX / side, height: event.scrollingDeltaY / side),
                     animated: false)
            }
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
    #endif
}
