import Foundation
import AppKit
import CoreGraphics

/// Captures global mouse events with high-precision timestamps relative to a recording start time.
/// Uses CGEventTap so we receive events from every application, not just our own.
final class MouseTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var startMachTime: UInt64 = 0
    private var displayOrigin: CGPoint = .zero
    private var displayScale: CGFloat = 1.0
    private let lock = NSLock()
    private var _events: [MouseEvent] = []

    /// Start a new tracking session. `displayOrigin` is the captured display's origin
    /// in global screen-point space; `displayScale` is its backing scale factor (e.g. 2.0).
    func start(displayOrigin: CGPoint, displayScale: CGFloat) -> Bool {
        stop()
        _events.removeAll()
        self.displayOrigin = displayOrigin
        self.displayScale = displayScale
        self.startMachTime = mach_absolute_time()

        // Built via reduce so Swift's type-checker doesn't choke on the
        // long left-shift OR chain (Xcode 16.x errors out with
        // "unable to type-check this expression in reasonable time").
        let interestedTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .scrollWheel,
            .leftMouseDragged, .rightMouseDragged,
            .keyDown,
        ]
        let mask: CGEventMask = interestedTypes.reduce(0) { acc, t in
            acc | (CGEventMask(1) << t.rawValue)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let tracker = Unmanaged<MouseTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() -> [MouseEvent] {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        return drain()
    }

    private func drain() -> [MouseEvent] {
        lock.lock(); defer { lock.unlock() }
        let result = _events
        _events.removeAll()
        return result
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let now = mach_absolute_time()
        let elapsed = Self.machTimeToSeconds(now &- startMachTime)
        let location = event.location // global screen coordinates, points

        // Convert to display-local pixel coordinates.
        let localX = (location.x - displayOrigin.x) * displayScale
        let localY = (location.y - displayOrigin.y) * displayScale

        let kind: MouseEvent.Kind
        var dx: Double = 0
        var dy: Double = 0
        switch type {
        case .mouseMoved: kind = .move
        case .leftMouseDown: kind = .leftDown
        case .leftMouseUp: kind = .leftUp
        case .rightMouseDown: kind = .rightDown
        case .rightMouseUp: kind = .rightUp
        case .leftMouseDragged, .rightMouseDragged: kind = .dragged
        case .scrollWheel:
            kind = .scroll
            dx = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
            dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        case .keyDown:
            // We deliberately ignore which key was pressed — keystrokes are
            // captured purely as activity-impulse timestamps so the auto-zoom
            // engine can detect "user is typing". The position fields are set
            // to 0 to make accidental misuse obvious.
            kind = .keyDown
            let evt = MouseEvent(time: elapsed, kind: kind, x: 0, y: 0)
            lock.lock()
            _events.append(evt)
            lock.unlock()
            return
        default:
            return
        }

        let evt = MouseEvent(time: elapsed, kind: kind, x: localX, y: localY, scrollDX: dx, scrollDY: dy)
        lock.lock()
        _events.append(evt)
        lock.unlock()
    }

    // MARK: - Mach time helpers

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machTimeToSeconds(_ delta: UInt64) -> Double {
        let nanos = Double(delta) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1_000_000_000.0
    }
}
