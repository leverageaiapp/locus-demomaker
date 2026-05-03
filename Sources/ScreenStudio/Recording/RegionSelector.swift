import Foundation
import AppKit
import ScreenCaptureKit

/// Pops a translucent full-screen overlay over `display`. Lets the user drag /
/// resize a rectangle and confirm. Returns the rect in **display-local point**
/// coordinates (origin = top-left of display) via `onDone`.
@MainActor
final class RegionSelector {
    /// Show the picker. Calls `onDone(nil)` if cancelled.
    static func present(
        on display: SCDisplay,
        initialRectInPoints: CGRect,
        onDone: @escaping (CGRect?) -> Void
    ) {
        // Find the NSScreen that backs this SCDisplay.
        guard let screen = NSScreen.screens.first(where: { screenID($0) == display.displayID })
                ?? NSScreen.main else {
            onDone(nil); return
        }

        // Convert the display-local rect to NSScreen coords (NSScreen origin
        // is bottom-left). The screen's frame is in *global* coordinates, so
        // we just need to flip Y within the display.
        let initialInScreen = displayPointsToScreenFrame(
            displayLocal: initialRectInPoints,
            screen: screen
        )

        let window = OverlayWindow(
            screen: screen,
            initialRectGlobal: initialInScreen
        )
        window.onConfirm = { confirmedGlobalRect in
            let rectInDisplay = screenFrameToDisplayPoints(
                screenFrame: confirmedGlobalRect,
                screen: screen
            )
            window.close()
            onDone(rectInDisplay)
        }
        window.onCancel = {
            window.close()
            onDone(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Coordinate conversion

    private static func screenID(_ screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Display-local point rect (top-left origin) → global NSScreen coordinates (bottom-left).
    private static func displayPointsToScreenFrame(
        displayLocal: CGRect,
        screen: NSScreen
    ) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: f.minX + displayLocal.minX,
            y: f.minY + (f.height - displayLocal.maxY),
            width: displayLocal.width,
            height: displayLocal.height
        )
    }

    /// Inverse — global screen rect → display-local points (top-left origin).
    private static func screenFrameToDisplayPoints(
        screenFrame: CGRect,
        screen: NSScreen
    ) -> CGRect {
        let f = screen.frame
        return CGRect(
            x: screenFrame.minX - f.minX,
            y: f.height - (screenFrame.minY - f.minY) - screenFrame.height,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }
}

// MARK: - Overlay window

private final class OverlayWindow: NSWindow {
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, initialRectGlobal: CGRect) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        // Set the frame explicitly so the window lands on `screen`.
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .modalPanel
        ignoresMouseEvents = false
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.windowGlobalOrigin = screen.frame.origin
        view.selectionRect = NSRect(
            x: initialRectGlobal.minX - screen.frame.minX,
            y: initialRectGlobal.minY - screen.frame.minY,
            width: initialRectGlobal.width,
            height: initialRectGlobal.height
        )
        view.onConfirm = { [weak self] rectInView in
            guard let self else { return }
            let global = NSRect(
                x: rectInView.minX + screen.frame.minX,
                y: rectInView.minY + screen.frame.minY,
                width: rectInView.width,
                height: rectInView.height
            )
            self.onConfirm?(global)
        }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay view

private final class OverlayView: NSView {
    enum DragMode {
        case none, move
        case resizeNW, resizeNE, resizeSW, resizeSE
        case createNew
    }

    /// Selection rect in this view's local coordinates (bottom-left origin).
    var selectionRect: NSRect = .zero { didSet { needsDisplay = true } }
    /// Origin of the screen this view sits on, in global coordinates — used so
    /// children can compute global rects when needed.
    var windowGlobalOrigin: NSPoint = .zero

    var onConfirm: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private var dragMode: DragMode = .none
    private var dragStart: NSPoint = .zero
    private var rectAtDragStart: NSRect = .zero
    private let handleSize: CGFloat = 12

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim the regions OUTSIDE the selection.
        NSColor.black.withAlphaComponent(0.45).setFill()
        let topRect    = NSRect(x: 0, y: selectionRect.maxY,
                                width: bounds.width,
                                height: max(0, bounds.height - selectionRect.maxY))
        let bottomRect = NSRect(x: 0, y: 0,
                                width: bounds.width, height: max(0, selectionRect.minY))
        let leftRect   = NSRect(x: 0, y: selectionRect.minY,
                                width: max(0, selectionRect.minX),
                                height: selectionRect.height)
        let rightRect  = NSRect(x: selectionRect.maxX, y: selectionRect.minY,
                                width: max(0, bounds.width - selectionRect.maxX),
                                height: selectionRect.height)
        topRect.fill()
        bottomRect.fill()
        leftRect.fill()
        rightRect.fill()

        // Selection border.
        let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        NSColor.controlAccentColor.setStroke()
        border.lineWidth = 2
        border.stroke()

        // Inner highlight to make the selection feel "lifted".
        let innerGlow = NSBezierPath(rect: selectionRect.insetBy(dx: 1.5, dy: 1.5))
        NSColor.white.withAlphaComponent(0.18).setStroke()
        innerGlow.lineWidth = 1
        innerGlow.stroke()

        // Corner handles.
        for h in handleRects() {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: h, xRadius: 2, yRadius: 2).fill()
            NSColor.controlAccentColor.setStroke()
            let stroked = NSBezierPath(roundedRect: h.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            stroked.lineWidth = 1
            stroked.stroke()
        }

        // HUD: dimensions + buttons.
        drawHUD()
    }

    private func drawHUD() {
        let dims = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: dims, attributes: attrs)
        let dimsSize = str.size()
        let pillRect = NSRect(
            x: selectionRect.midX - dimsSize.width / 2 - 10,
            y: selectionRect.maxY + 10,
            width: dimsSize.width + 20,
            height: 24
        )
        let pillBg = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.7).setFill()
        pillBg.fill()
        str.draw(at: NSPoint(x: pillRect.minX + 10, y: pillRect.minY + 4))

        // Hint along the bottom.
        let hint = "Drag to move · Drag corners to resize · ↩ Confirm · Esc Cancel"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let hintStr = NSAttributedString(string: hint, attributes: hintAttrs)
        let size = hintStr.size()
        let hintRect = NSRect(
            x: bounds.midX - size.width / 2 - 14,
            y: 24,
            width: size.width + 28, height: 30
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: hintRect, xRadius: 8, yRadius: 8).fill()
        hintStr.draw(at: NSPoint(x: hintRect.minX + 14, y: hintRect.minY + 7))
    }

    private func handleRects() -> [NSRect] {
        let s = handleSize
        let r = selectionRect
        return [
            NSRect(x: r.minX - s/2, y: r.minY - s/2, width: s, height: s),  // SW
            NSRect(x: r.maxX - s/2, y: r.minY - s/2, width: s, height: s),  // SE
            NSRect(x: r.minX - s/2, y: r.maxY - s/2, width: s, height: s),  // NW
            NSRect(x: r.maxX - s/2, y: r.maxY - s/2, width: s, height: s)   // NE
        ]
    }

    // MARK: Hit testing

    private func hitTestSelection(_ p: NSPoint) -> DragMode {
        let s = handleSize
        let r = selectionRect
        let near: (NSPoint, NSPoint) -> Bool = { a, b in
            abs(a.x - b.x) <= s/2 + 2 && abs(a.y - b.y) <= s/2 + 2
        }
        if near(p, NSPoint(x: r.minX, y: r.minY)) { return .resizeSW }
        if near(p, NSPoint(x: r.maxX, y: r.minY)) { return .resizeSE }
        if near(p, NSPoint(x: r.minX, y: r.maxY)) { return .resizeNW }
        if near(p, NSPoint(x: r.maxX, y: r.maxY)) { return .resizeNE }
        if NSPointInRect(p, r) { return .move }
        return .createNew
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        dragStart = p
        rectAtDragStart = selectionRect
        dragMode = hitTestSelection(p)
        if dragMode == .createNew {
            selectionRect = NSRect(x: p.x, y: p.y, width: 1, height: 1)
            rectAtDragStart = selectionRect
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let dx = p.x - dragStart.x
        let dy = p.y - dragStart.y
        var r = rectAtDragStart
        switch dragMode {
        case .move:
            r.origin.x += dx
            r.origin.y += dy
        case .resizeSW:
            r.origin.x += dx; r.origin.y += dy
            r.size.width -= dx; r.size.height -= dy
        case .resizeSE:
            r.origin.y += dy
            r.size.width += dx; r.size.height -= dy
        case .resizeNW:
            r.origin.x += dx
            r.size.width -= dx; r.size.height += dy
        case .resizeNE:
            r.size.width += dx; r.size.height += dy
        case .createNew:
            r = NSRect(
                x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                width:  abs(p.x - dragStart.x), height: abs(p.y - dragStart.y)
            )
        case .none: return
        }
        selectionRect = clamp(rect: r, into: bounds, minSize: NSSize(width: 80, height: 60))
    }

    override func mouseUp(with event: NSEvent) {
        dragMode = .none
    }

    private func clamp(rect r: NSRect, into bounds: NSRect, minSize: NSSize) -> NSRect {
        var out = r
        out.size.width  = max(minSize.width,  out.size.width)
        out.size.height = max(minSize.height, out.size.height)
        out.size.width  = min(out.size.width,  bounds.width)
        out.size.height = min(out.size.height, bounds.height)
        out.origin.x = max(0, min(out.origin.x, bounds.width  - out.size.width))
        out.origin.y = max(0, min(out.origin.y, bounds.height - out.size.height))
        return out
    }

    // MARK: Cursor

    override func resetCursorRects() {
        for r in handleRects() {
            addCursorRect(r, cursor: .crosshair)
        }
        addCursorRect(selectionRect, cursor: .openHand)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:                       // Esc
            onCancel?()
        case 36, 76:                   // Return / Enter
            onConfirm?(selectionRect)
        default:
            super.keyDown(with: event)
        }
    }
}
