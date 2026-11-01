import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

/// Makes an event draggable onto another day of a grid (iPad, Mac; editors only), shown as a
/// chip with its title (`CalendarEventDragItem`). `day` is the one of its days it shows on: an
/// event that spans days moves by as many days as it is dragged. In the month in detail
/// (`inGrid`) its label also tells the grid where it is (`CalendarStore.eventLabels`), so a press
/// there drags the event instead of selecting days; on the Mac a click on it then does what a
/// click on its day does, a double click opens the event.
struct CalendarEventDragSource: ViewModifier {
    let store: CalendarStore
    let event: CalendarEvent
    var day: Day?
    let enabled: Bool
    var inGrid = false
    @Environment(CalendarActions.self) private var actions: CalendarActions?
    #if os(macOS)
    @State private var lastClick = Date.distantPast
    #endif

    func body(content: Content) -> some View {
        if enabled {
            let day = day ?? event.date
            let item = store.dragItem(event, on: day)
            let dragged = content
                .contentShape(.rect)
                .draggable(item) { CalendarEventDragPreview(event: event) }
            if inGrid {
                let key = "\(event.uid)@\(day)"
                let space = CalendarMonthGrid.space(year: day.year, month: day.month)
                dragged
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
                        store.eventLabels[key] = (day, frame)
                    }
                    .onDisappear { store.eventLabels[key] = nil }
                    #if os(macOS)
                    .onTapGesture { click() }
                    #endif
            } else {
                dragged
            }
        } else {
            content
        }
    }

    #if os(macOS)
    /// The grid's own click doesn't reach the label (`CalendarPointerSelection` yields to it).
    private func click() {
        let now = Date()
        if now.timeIntervalSince(lastClick) < NSEvent.doubleClickInterval {
            lastClick = .distantPast
            actions?.editEvent(event)
            return
        }
        lastClick = now
        let modifiers = CalendarModifiers.current
        store.tap(day ?? event.date, extend: modifiers.contains(.shift), toggle: modifiers.contains(.command))
    }
    #endif
}

/// A dragged event: its title in a chip.
struct CalendarEventDragPreview: View {
    let event: CalendarEvent

    var body: some View {
        Label(event.title, systemImage: event.isAppointment ? "stethoscope" : "clock")
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.cardBackground, in: .capsule)
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.5))
            .fixedSize()
    }
}

/// A grid as the place to drop an event (`CalendarEventDragItem`): the day under the pointer
/// shows as the target (`CalendarStore.dropTarget`), dropping moves the event there. `day`
/// finds the day at a point of the view the drop is on (nil: none there).
struct CalendarEventDrop: DropDelegate {
    let store: CalendarStore
    let day: (CGPoint) -> Day?

    func validateDrop(info: DropInfo) -> Bool {
        !store.readOnly && info.hasItemsConforming(to: [.ohanaCalendarEvent])
    }

    func dropEntered(info: DropInfo) {
        store.setDropTarget(day(info.location))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = day(info.location)
        store.setDropTarget(target)
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        store.setDropTarget(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        store.setDropTarget(nil)
        guard let target = day(info.location),
              let provider = info.itemProviders(for: [.ohanaCalendarEvent]).first else { return false }
        let store = store
        _ = provider.loadTransferable(type: CalendarEventDragItem.self) { result in
            guard case let .success(item) = result else { return }
            Task { @MainActor in store.dropEvent(item, on: target) }
        }
        return true
    }
}
