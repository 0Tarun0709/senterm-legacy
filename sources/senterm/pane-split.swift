import SwiftUI

struct PaneSplit<First: View, Second: View>: View {
    let vertical: Bool
    let first: First
    let second: Second
    var zoomFirst: Bool? = nil
    let divider: UUID
    let balancedRatio: CGFloat
    let adjustment: PaneAdjustment?
    @Environment(\.colorScheme) private var colorScheme
    @State private var ratio: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let length = vertical ? size.height : size.width
            let gap = min(1, length)
            let available = length - gap
            let minimum = min(vertical ? 60.0 : 90.0, available / 2)
            let offset = min(max(available * ratio, minimum), available - minimum)

            ZStack(alignment: .topLeading) {
                first.frame(width: vertical || zoomFirst == true ? size.width : offset,
                            height: !vertical || zoomFirst == true ? size.height : offset)
                    .clipped()
                    .opacity(zoomFirst == false ? 0 : 1)
                    .allowsHitTesting(zoomFirst != false)
                    .accessibilityHidden(zoomFirst == false)
                second.frame(width: vertical || zoomFirst == false ? size.width : available - offset,
                             height: !vertical || zoomFirst == false ? size.height : available - offset)
                    .clipped()
                    .offset(x: vertical || zoomFirst == false ? 0 : offset + gap,
                            y: !vertical || zoomFirst == false ? 0 : offset + gap)
                    .opacity(zoomFirst == true ? 0 : 1)
                    .allowsHitTesting(zoomFirst != true)
                    .accessibilityHidden(zoomFirst == true)
                SplitHandle(vertical: vertical, offset: offset, light: colorScheme == .light, resize: { position in
                    guard available > 0 else { return }
                    ratio = min(max(position, minimum), available - minimum) / available
                }, reset: { ratio = 0.5 })
                    .frame(width: vertical ? size.width : 7, height: vertical ? 7 : size.height)
                    .position(x: vertical ? size.width / 2 : offset + gap / 2,
                              y: vertical ? offset + gap / 2 : size.height / 2)
                    .opacity(zoomFirst == nil ? 1 : 0)
                    .allowsHitTesting(zoomFirst == nil)
                    .accessibilityHidden(zoomFirst != nil)
                    .accessibilityLabel("split divider")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: ratio = min(1, ratio + 0.1)
                        case .decrement: ratio = max(0, ratio - 0.1)
                        @unknown default: break
                        }
                    }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .onChange(of: adjustment) { adjustment in
                guard let adjustment else { return }
                if adjustment.divider == nil {
                    ratio = balancedRatio
                } else if adjustment.divider == divider, available > 0 {
                    ratio = min(max(offset + adjustment.points, minimum), available - minimum) / available
                }
            }
        }
    }
}

// Use an AppKit hit target alongside the AppKit terminal surfaces.
private struct SplitHandle: NSViewRepresentable {
    let vertical: Bool
    let offset: CGFloat
    let light: Bool
    let resize: (CGFloat) -> Void
    let reset: () -> Void

    func makeNSView(context: Context) -> Handle { Handle() }

    func updateNSView(_ view: Handle, context: Context) {
        view.configuration = self
        view.needsDisplay = true
    }

    final class Handle: NSView {
        var configuration: SplitHandle?
        private var dragStart: (point: NSPoint, offset: CGFloat)?

        override func draw(_ dirtyRect: NSRect) {
            guard let configuration else { return }
            (configuration.light ? NSColor.black : .white).withAlphaComponent(0.18).setFill()
            let line = configuration.vertical
                ? NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1)
                : NSRect(x: bounds.midX - 0.5, y: 0, width: 1, height: bounds.height)
            line.fill()
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: configuration?.vertical == true ? .resizeUpDown : .resizeLeftRight)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let configuration else { return }
            if event.clickCount == 2 { configuration.reset() }
            dragStart = event.clickCount == 2 ? nil : (event.locationInWindow, configuration.offset)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let configuration, let dragStart else { return }
            let point = event.locationInWindow
            let distance = configuration.vertical ? dragStart.point.y - point.y : point.x - dragStart.point.x
            configuration.resize(dragStart.offset + distance)
        }

        override func mouseUp(with event: NSEvent) { dragStart = nil }
    }
}
