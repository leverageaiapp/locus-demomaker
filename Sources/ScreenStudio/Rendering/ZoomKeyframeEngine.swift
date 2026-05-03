import Foundation
import CoreGraphics

/// One sample of the auto-zoom curve at a particular video time.
struct ZoomKeyframe: Sendable {
    let time: Double
    /// Focus point in source video pixel coordinates (origin top-left).
    let focusX: Double
    let focusY: Double
    /// Zoom factor, where 1.0 = fit-to-frame, >1.0 = zoom in.
    let zoom: Double
}

/// Converts a stream of mouse events into a smooth auto-zoom curve.
///
/// Algorithm overview:
///   1. Sample raw mouse position at fixed intervals (matching video framerate).
///   2. Compute an "activity" signal that spikes on clicks/scrolls and decays exponentially.
///   3. Target zoom = lerp(idleZoom, activeZoom, activity).
///   4. Smooth the focus point and zoom independently with a critically damped second-order
///      filter so the camera never overshoots and never twitches on small mouse jitter.
struct ZoomKeyframeEngine {
    struct Config {
        var idleZoom: Double = 1.0
        var activeZoom: Double = 1.6
        var activityHalfLife: Double = 1.2  // seconds
        var activityFromMovement: Double = 0.0015  // per pixel/sec of mouse speed
        var clickActivity: Double = 1.0
        var scrollActivity: Double = 0.6
        /// Idle threshold: if recent activity < this, snap toward idleZoom.
        var idleThreshold: Double = 0.05
        /// Spring natural frequency for focus tracking (rad/s). Higher = snappier.
        var focusOmega: Double = 5.5
        /// Spring natural frequency for zoom tracking (rad/s). Lower = smoother zoom.
        var zoomOmega: Double = 3.0
        /// Time before any event when zoom should start anticipating it.
        var anticipation: Double = 0.4
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Generate one keyframe per video frame.
    func generate(events: [MouseEvent], duration: Double, frameRate: Int,
                  videoSize: CGSize) -> [ZoomKeyframe] {
        let dt = 1.0 / Double(max(frameRate, 1))
        let frameCount = max(1, Int((duration / dt).rounded()))

        // 1. Build a per-frame activity signal & raw target focus.
        var activity = [Double](repeating: 0, count: frameCount)
        var rawFocusX = [Double](repeating: videoSize.width / 2, count: frameCount)
        var rawFocusY = [Double](repeating: videoSize.height / 2, count: frameCount)

        let decay = log(2.0) / max(config.activityHalfLife, 0.01)

        // Accumulate impulses + carry forward last known mouse position.
        var lastPos = CGPoint(x: videoSize.width / 2, y: videoSize.height / 2)
        var lastEventTime: Double = 0
        var eventIdx = 0
        let sortedEvents = events.sorted { $0.time < $1.time }

        for f in 0..<frameCount {
            let t = Double(f) * dt
            // Drain events whose time <= current frame time.
            while eventIdx < sortedEvents.count && sortedEvents[eventIdx].time <= t {
                let e = sortedEvents[eventIdx]
                lastPos = CGPoint(x: e.x, y: e.y)
                lastEventTime = e.time

                let dtSinceLast = max(0.001, t - lastEventTime)
                var impulse: Double = 0
                switch e.kind {
                case .leftDown, .rightDown: impulse += config.clickActivity
                case .scroll: impulse += config.scrollActivity
                case .move, .dragged:
                    let dx = e.x - rawFocusX[max(f - 1, 0)]
                    let dy = e.y - rawFocusY[max(f - 1, 0)]
                    let speed = sqrt(dx * dx + dy * dy) / dtSinceLast
                    impulse += min(1.0, speed * config.activityFromMovement)
                default: break
                }
                if f < activity.count {
                    activity[f] += impulse
                }
                eventIdx += 1
            }
            rawFocusX[f] = lastPos.x
            rawFocusY[f] = lastPos.y
        }

        // 2. Exponentially smooth activity (causal — past events influence future zoom).
        for f in 1..<frameCount {
            activity[f] = activity[f] + activity[f - 1] * exp(-decay * dt)
        }
        // Clamp to [0, 1].
        for f in 0..<frameCount {
            activity[f] = max(0, min(1, activity[f]))
        }

        // 3. Anticipation pass — let zoom rise slightly *before* a high-activity frame
        // so the viewer doesn't see the cursor before the camera arrives.
        let anticipationFrames = Int(config.anticipation / dt)
        if anticipationFrames > 0 {
            var anticipated = activity
            for f in 0..<frameCount {
                let end = min(frameCount - 1, f + anticipationFrames)
                var maxAhead: Double = 0
                for g in f...end {
                    let weight = 1.0 - Double(g - f) / Double(anticipationFrames + 1)
                    maxAhead = max(maxAhead, activity[g] * weight)
                }
                anticipated[f] = max(activity[f], maxAhead)
            }
            activity = anticipated
        }

        // 4. Critically damped second-order filter for focus + zoom.
        var focusX: Double = Double(videoSize.width / 2)
        var focusY: Double = Double(videoSize.height / 2)
        var focusVX: Double = 0
        var focusVY: Double = 0
        var zoom = config.idleZoom
        var zoomV: Double = 0

        var keyframes = [ZoomKeyframe]()
        keyframes.reserveCapacity(frameCount)

        for f in 0..<frameCount {
            let t = Double(f) * dt
            let a = activity[f]
            let targetZoom = a < config.idleThreshold
                ? config.idleZoom
                : config.idleZoom + (config.activeZoom - config.idleZoom) * a
            let targetX: Double = a < config.idleThreshold ? Double(videoSize.width / 2) : rawFocusX[f]
            let targetY: Double = a < config.idleThreshold ? Double(videoSize.height / 2) : rawFocusY[f]

            (focusX, focusVX) = criticallyDampedStep(
                value: focusX, velocity: focusVX, target: targetX,
                omega: config.focusOmega, dt: dt
            )
            (focusY, focusVY) = criticallyDampedStep(
                value: focusY, velocity: focusVY, target: targetY,
                omega: config.focusOmega, dt: dt
            )
            (zoom, zoomV) = criticallyDampedStep(
                value: zoom, velocity: zoomV, target: targetZoom,
                omega: config.zoomOmega, dt: dt
            )

            keyframes.append(ZoomKeyframe(time: t, focusX: focusX, focusY: focusY, zoom: zoom))
        }

        return keyframes
    }

    /// Closed-form critically damped spring step (no overshoot).
    private func criticallyDampedStep(value: Double, velocity: Double, target: Double,
                                      omega: Double, dt: Double) -> (Double, Double) {
        let x = value - target
        let exp_ = exp(-omega * dt)
        let newX = (x + (velocity + omega * x) * dt) * exp_
        let newV = (velocity - (velocity + omega * x) * omega * dt) * exp_
        return (newX + target, newV)
    }
}
