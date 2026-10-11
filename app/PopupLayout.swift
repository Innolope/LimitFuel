import AppKit
import Combine

enum PopupLayout {
    static func viewportHeight(contentHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let maximum = availableHeight.isFinite && availableHeight > 0 ? min(availableHeight, 600) : 600
        let desired = contentHeight.isFinite && contentHeight > 0 ? contentHeight : 250
        return min(maximum, max(100, desired))
    }
}

// One source of truth for the SwiftUI viewport and NSPopover content size.
// Measuring the document, rather than the viewport, avoids a sizing feedback loop.
final class PopupPresentation: ObservableObject {
    @Published private(set) var viewportHeight: CGFloat = 250
    @Published private(set) var opening = UUID()
    private var contentHeight: CGFloat = 250
    private var availableHeight: CGFloat = 600
    var onResize: ((CGFloat) -> Void)?

    func measure(contentHeight: CGFloat) {
        self.contentHeight = contentHeight
        resize()
    }

    func constrain(availableHeight: CGFloat) {
        self.availableHeight = availableHeight
        resize()
    }

    func beginPresentation() {
        opening = UUID()
    }

    private func resize() {
        let height = PopupLayout.viewportHeight(contentHeight: contentHeight, availableHeight: availableHeight)
        guard viewportHeight != height else { return }
        viewportHeight = height
        onResize?(height)
    }
}
