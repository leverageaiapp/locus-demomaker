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

    /// The clickable "↩ Confirm" pill, in view coordinates. Recomputed on each
    /// draw and consulted by mouseDown so a click on it confirms.
    private var confirmPillRect: NSRect = .zero

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
        // 1. Dimensions pill above the rect.
        let dims = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let dimStr = NSAttributedString(string: dims, attributes: dimAttrs)
        let dimSize = dimStr.size()
        let dimRect = NSRect(
            x: selectionRect.midX - dimSize.width / 2 - 10,
            y: selectionRect.maxY + 10,
            width: dimSize.width + 20,
            height: dimSize.height + 8
        )
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: dimRect, xRadius: 6, yRadius: 6).fill()
        dimStr.draw(at: NSPoint(x: dimRect.minX + 10, y: dimRect.minY + 4))

        // 2. Big colored "↩ Confirm" pill INSIDE the rect, near the bottom — also clickable.
        let confirmText = "↩  Press Enter to confirm"
        let confirmAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let cStr = NSAttributedString(string: confirmText, attributes: confirmAttrs)
        let cSize = cStr.size()
        // Anchor inside the bottom of the rect; if the rect is too short, float
        // it just above the bottom edge so it's still visible.
        let pillW = cSize.width + 32
        let pillH: CGFloat = 36
        let canFitInside = selectionRect.height > pillH + 24
        let pillY = canFitInside
            ? selectionRect.minY + 14
            : max(8, selectionRect.minY - pillH - 10)
        let pill = NSRect(
            x: selectionRect.midX - pillW / 2,
            y: pillY,
            width: pillW, height: pillH
        )
        confirmPillRect = pill
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
        // Subtle inner highlight.
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let inner = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        inner.lineWidth = 1
        inner.stroke()
        cStr.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + (pillH - cSize.height) / 2))

        // 3. Bottom hint strip.
        let hint = "Drag to move · Drag corners to resize · Esc to cancel"
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let hintStr = NSAttributedString(string: hint, attributes: hintAttrs)
        let hintSize = hintStr.size()
        let hintRect = NSRect(
            x: bounds.midX - hintSize.width / 2 - 14,
            y: 24,
            width: hintSize.width + 28, height: hintSize.height + 12
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: hintRect, xRadius: 8, yRadius: 8).fill()
        hintStr.draw(at: NSPoint(x: hintRect.minX + 14, y: hintRect.minY + 6))
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
        // Click on the Confirm pill = confirm.
        if !confirmPillRect.isEmpty && NSPointInRect(p, confirmPillRect) {
            onConfirm?(selectionRect)
            return
        }
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
        if !confirmPillRect.isEmpty {
            addCursorRect(confirmPillRect, cursor: .pointingHand)
        }
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
