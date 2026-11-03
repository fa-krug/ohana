import SwiftUI

extension View {
    /// A tooltip: on the Mac the system's on hover (`.help`), on iPhone and iPad a small bubble
    /// after a long press (`.help` does nothing on touch), with a light tap of haptics. It doesn't
    /// take taps: a view that toggles on a tap keeps its `.onTapGesture` (put it before this) and a
    /// long press shows the tip without it. Not for a view inside a `Button` or `NavigationLink`
    /// (there a long press means something already, and the button would fire on release).
    func longPressTip(_ text: String) -> some View {
        modifier(LongPressTip(text: text))
    }
}

private struct LongPressTip: ViewModifier {
    let text: String
    #if os(iOS)
    @State private var shown = false
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onLongPressGesture(minimumDuration: 0.4) { shown = true }
            .popover(isPresented: $shown) {
                Text(text)
                    .font(.footnote)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // A bubble on iPhone too, not a sheet.
                    .presentationCompactAdaptation(.popover)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: shown) { _, new in new }
        #else
        content.help(text)
        #endif
    }
}
