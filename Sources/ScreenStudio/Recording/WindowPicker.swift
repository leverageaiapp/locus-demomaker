import Foundation
import AppKit
import ScreenCaptureKit

/// Pops a translucent overlay over `display`. As the cursor moves, the topmost
/// user-facing window beneath it gets highlighted; clicking confirms.
@MainActor
final class WindowPicker {
    static func present(
        on display: SCDisplay,
        windows: [SCWindow],
        onDone: @escaping (SCWindow?) -> Void
    ) {
        guard let screen = NSScreen.screens.first(where: { screenID($0) == display.displayID })
                ?? NSScreen.main else {
            onDone(nil); return
        }
        let window = OverlayWindow(screen: screen, windows: windows)
        window.onPick = { picked in
            window.close()
            onDone(picked)
        }
        window.onCancel = {
            window.close()
            onDone(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func screenID(_ s: NSScreen) -> CGDirectDisplayID? {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Overlay window

private final class OverlayWindow: NSWindow {
    var onPick: ((SCWindow?) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, windows: [SCWindow]) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .modalPanel
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.windows = windows
        view.targetScreen = screen
        view.onPick = { [weak self] w in self?.onPick?(w) }
        view.onCancel = { [weak self] in self?.onCancel?() }
        contentView = view
        makeFirstResponder(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Overlay view

private final class OverlayView: NSView {
    var windows: [SCWindow] = []     // already filtered + ordered front-to-back
    var targetScreen: NSScreen = .main!
    var onPick: ((SCWindow) -> Void)?
    var onCancel: (() -> Void)?

    private var hovered: SCWindow? { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Initial highlight so it's not blank before the user moves.
        if hovered == nil, let p = window?.mouseLocationOutsideOfEventStream {
            hovered = windowAt(viewPoint: convert(p, from: nil))
            needsDisplay = true
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = windowAt(viewPoint: p)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let w = windowAt(viewPoint: p) ?? hovered {
            onPick?(w)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {       // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Geometry

    /// Topmost SCWindow whose Quartz frame contains the given view-local point.
    private func windowAt(viewPoint: NSPoint) -> SCWindow? {
        let q = pointInQuartz(viewPoint: viewPoint)
        return windows.first { $0.frame.contains(q) }
    }

    /// View-local Cocoa (bottom-left) → global Quartz (top-left).
    private func pointInQuartz(viewPoint: NSPoint) -> CGPoint {
        let globalCocoa = NSPoint(
            x: viewPoint.x + targetScreen.frame.origin.x,
            y: viewPoint.y + targetScreen.frame.origin.y
        )
        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        return CGPoint(x: globalCocoa.x, y: primaryHeight - globalCocoa.y)
    }

    /// SCWindow.frame (Quartz) → view-local Cocoa rect.
    private func quartzRectToView(_ q: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
        let globalCocoa = NSRect(
            x: q.origin.x,
            y: primaryHeight - q.origin.y - q.size.height,
            width: q.size.width, height: q.size.height
        )
        return NSRect(
            x: globalCocoa.origin.x - targetScreen.frame.origin.x,
            y: globalCocoa.origin.y - targetScreen.frame.origin.y,
            width: globalCocoa.width, height: globalCocoa.height
        )
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Light dim across the whole screen.
        NSColor.black.withAlphaComponent(0.30).setFill()
        bounds.fill()

        if let w = hovered {
            let viewRect = quartzRectToView(w.frame)

            // Tinted fill over the highlighted window.
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            viewRect.fill()

            // Bright border.
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: viewRect.insetBy(dx: 1.5, dy: 1.5))
            path.lineWidth = 3
            path.stroke()

            // Title pill above the rect.
            let app = w.owningApplication?.applicationName ?? ""
            let title = (w.title?.isEmpty == false) ? w.title! : app
            let label = app.isEmpty ? title : "\(app) — \(title)"
            drawPill(text: label, font: .systemFont(ofSize: 13, weight: .medium),
                     centerX: viewRect.midX,
                     bottom: min(bounds.height - 30, viewRect.maxY + 12),
                     bg: NSColor.black.withAlphaComponent(0.78),
                     fg: .white)
        }

        // Bottom hint.
        let hint = hovered == nil
            ? "Move the cursor over a window — click to record it · Esc to cancel"
            : "Click to select this window · Esc to cancel"
        drawPill(
            text: hint, font: .systemFont(ofSize: 12),
            centerX: bounds.midX,
            bottom: 24,
            bg: NSColor.black.withAlphaComponent(0.65),
            fg: NSColor.white.withAlphaComponent(0.9)
        )
    }

    private func drawPill(text: String, font: NSFont, centerX: CGFloat, bottom: CGFloat,
                          bg: NSColor, fg: NSColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let rect = NSRect(
            x: centerX - size.width / 2 - 14,
            y: bottom,
            width: size.width + 28, height: size.height + 12
        )
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        str.draw(at: NSPoint(x: rect.minX + 14, y: rect.minY + 6))
    }
}
