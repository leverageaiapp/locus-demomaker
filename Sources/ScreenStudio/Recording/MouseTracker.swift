import Foundation
import AppKit
import CoreGraphics

/// Captures global mouse events with high-precision timestamps relative to a recording start time.
/// Uses CGEventTap so we receive events from every application, not just our own.
final class MouseTracker {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The tap runs on its own thread's runloop. On the main runloop, UI work
    /// (recording timer, animations) starves the tap and macOS coalesces
    /// mouse-moved events down to a few per second — which made the exported
    /// cursor and camera path visibly choppy.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var startMachTime: UInt64 = 0
    private var startUptime: TimeInterval = 0
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
        self.startUptime = ProcessInfo.processInfo.systemUptime

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
            // macOS disables a tap it considers slow; re-enable and keep going
            // instead of silently losing the rest of the recording.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = tracker.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }
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
        self.eventTap = tap
        self.runLoopSource = source

        // Dedicated thread so UI load can never starve event delivery.
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = self.runLoopSource else {
                ready.signal()
                return
            }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.screenstudio.mousetap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()
        _ = ready.wait(timeout: .now() + 2)
        return true
    }

    @discardableResult
    func stop() -> [MouseEvent] {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource, let rl = tapRunLoop {
                CFRunLoopRemoveSource(rl, src, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        tapThread = nil
        return drain()
    }

    private func drain() -> [MouseEvent] {
        lock.lock(); defer { lock.unlock() }
        let result = _events
        _events.removeAll()
        return result
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // Use the event's own occurrence time, not the callback's. The tap
        // runs on the main runloop — when the UI is busy, callbacks arrive
        // late and bunched, and stamping them at callback time makes the
        // exported cursor look sticky and unresponsive.
        let elapsed: Double
        if let nsEvent = NSEvent(cgEvent: event) {
            elapsed = nsEvent.timestamp - startUptime
        } else {
            elapsed = Self.machTimeToSeconds(mach_absolute_time() &- startMachTime)
        }
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
