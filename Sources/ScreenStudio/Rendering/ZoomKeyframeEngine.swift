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

/// Converts a stream of mouse + keyboard events into a smooth auto-zoom curve.
///
/// Algorithm:
///   1. Per-frame **activity signal** that spikes on click / scroll / fast move /
///      key-press impulses and decays exponentially.
///   2. Sub-frame **position resampling** with linear interpolation between
///      adjacent mouse-position events — kills the staircase artefact that
///      arose when several events arrived inside a single 16.6 ms frame slot.
///   3. **IIR low-pass** on the resampled position to take the edge off
///      operating-system mouse jitter before it reaches the spring.
///   4. **Hysteresis** on the idle decision — focus only re-centers after the
///      activity has been below threshold for `idleHoldTime` seconds straight,
///      so a brief dip during slow movement never triggers a "snap to center".
///   5. **Anticipation** look-ahead so zoom rises before a click, not after.
///   6. **Critically damped springs** for focus + zoom — no overshoot.
///   7. Typing is **pinned to the last click position**: keyDown events feed
///      activity but do *not* update the position target, so when a user is
///      typing we hold the camera on whatever input field they last clicked.
struct ZoomKeyframeEngine {
    struct Config {
        var idleZoom: Double = 1.0
        var activeZoom: Double = 1.6
        var activityHalfLife: Double = 1.2  // seconds
        var activityFromMovement: Double = 0.0015  // per pixel/sec of mouse speed
        var clickActivity: Double = 1.0
        var scrollActivity: Double = 0.6
        /// Activity contributed by each keyDown — high enough to keep the
        /// camera latched onto the input field while the user is typing.
        var keyActivity: Double = 0.55
        /// Below this activity, the focus is *eligible* to re-center.
        var idleThreshold: Double = 0.05
        /// How long activity must stay below threshold before we actually
        /// snap focus back to screen center. (0.8 s = a comfortable pause.)
        var idleHoldTime: Double = 0.8
        /// Time-constant of the raw-mouse low-pass filter, in seconds.
        var mouseLowPassTau: Double = 0.030
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
        let centerX = Double(videoSize.width / 2)
        let centerY = Double(videoSize.height / 2)
        let sortedEvents = events.sorted { $0.time < $1.time }

        // ── 1. Per-frame activity signal ────────────────────────────────────
        var activity = [Double](repeating: 0, count: frameCount)
        let decay = log(2.0) / max(config.activityHalfLife, 0.01)

        // For movement-speed impulses we need the previous position so we can
        // measure speed between events. Track it independently from the focus
        // resampling pass below.
        var prevMovePos: CGPoint? = nil
        var prevMoveTime: Double = 0

        var ei = 0
        for f in 0..<frameCount {
            let t = Double(f) * dt
            while ei < sortedEvents.count && sortedEvents[ei].time <= t {
                let e = sortedEvents[ei]
                var impulse: Double = 0
                switch e.kind {
                case .leftDown, .rightDown:
                    impulse += config.clickActivity
                case .scroll:
                    impulse += config.scrollActivity
                case .keyDown:
                    impulse += config.keyActivity
                case .move, .dragged:
                    if let p0 = prevMovePos {
                        let dts = max(0.001, e.time - prevMoveTime)
                        let dx = e.x - p0.x
                        let dy = e.y - p0.y
                        let speed = sqrt(dx * dx + dy * dy) / dts
                        impulse += min(1.0, speed * config.activityFromMovement)
                    }
                    prevMovePos = CGPoint(x: e.x, y: e.y)
                    prevMoveTime = e.time
                default:
                    break
                }
                if f < activity.count {
                    activity[f] += impulse
                }
                ei += 1
            }
        }

        // Causal exponential smoothing.
        for f in 1..<frameCount {
            activity[f] = activity[f] + activity[f - 1] * exp(-decay * dt)
        }
        for f in 0..<frameCount {
            activity[f] = max(0, min(1, activity[f]))
        }

        // Anticipation — let zoom rise *before* a click.
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

        // ── 2. Sub-frame position resampling ────────────────────────────────
        // Only events that carry a real cursor position participate. keyDown
        // events are skipped here — that's how typing pins the focus at the
        // last clicked location.
        let posEvents = sortedEvents.filter { e in
            switch e.kind {
            case .keyDown:                         return false
            case .leftUp, .rightUp:                return true
            case .move, .dragged, .scroll,
                 .leftDown, .rightDown:            return true
            }
        }

        var rawX = [Double](repeating: centerX, count: frameCount)
        var rawY = [Double](repeating: centerY, count: frameCount)

        if posEvents.isEmpty {
            // No mouse activity at all — leave at center.
        } else {
            // Before the first event, hold the first event's position so the
            // camera doesn't sweep in from center.
            let first = posEvents.first!
            for f in 0..<frameCount {
                let t = Double(f) * dt
                if t < first.time {
                    rawX[f] = first.x
                    rawY[f] = first.y
                } else {
                    break
                }
            }

            var pi = 0
            for f in 0..<frameCount {
                let t = Double(f) * dt
                if t < first.time { continue }
                while pi + 1 < posEvents.count && posEvents[pi + 1].time <= t {
                    pi += 1
                }
                let p0 = posEvents[pi]
                if pi + 1 < posEvents.count {
                    let p1 = posEvents[pi + 1]
                    let span = max(1e-6, p1.time - p0.time)
                    let r = min(1, max(0, (t - p0.time) / span))
                    rawX[f] = p0.x + (p1.x - p0.x) * r
                    rawY[f] = p0.y + (p1.y - p0.y) * r
                } else {
                    rawX[f] = p0.x
                    rawY[f] = p0.y
                }
            }
        }

        // ── 3. IIR low-pass on the raw position ─────────────────────────────
        let alpha = dt / (config.mouseLowPassTau + dt)
        var fx = rawX[0]
        var fy = rawY[0]
        for f in 0..<frameCount {
            fx += alpha * (rawX[f] - fx)
            fy += alpha * (rawY[f] - fy)
            rawX[f] = fx
            rawY[f] = fy
        }

        // ── 4. Spring-driven keyframes with hysteresis idle detection ───────
        let idleFramesNeeded = max(1, Int(config.idleHoldTime / dt))
        var idleStreak = 0

        var camX: Double = centerX
        var camY: Double = centerY
        var camVX: Double = 0
        var camVY: Double = 0
        var camZoom = config.idleZoom
        var camZoomV: Double = 0

        var keyframes = [ZoomKeyframe]()
        keyframes.reserveCapacity(frameCount)

        for f in 0..<frameCount {
            let t = Double(f) * dt
            let a = activity[f]

            if a < config.idleThreshold {
                idleStreak += 1
            } else {
                idleStreak = 0
            }
            let isIdle = idleStreak >= idleFramesNeeded

            // Zoom fades out naturally with activity — no hard switch.
            let targetZoom = config.idleZoom
                + (config.activeZoom - config.idleZoom) * a
            // Focus only snaps back to center after a confirmed long pause;
            // brief activity dips during a single mouse stroke do not.
            let targetX: Double = isIdle ? centerX : rawX[f]
            let targetY: Double = isIdle ? centerY : rawY[f]

            (camX, camVX) = criticallyDampedStep(
                value: camX, velocity: camVX, target: targetX,
                omega: config.focusOmega, dt: dt
            )
            (camY, camVY) = criticallyDampedStep(
                value: camY, velocity: camVY, target: targetY,
                omega: config.focusOmega, dt: dt
            )
            (camZoom, camZoomV) = criticallyDampedStep(
                value: camZoom, velocity: camZoomV, target: targetZoom,
                omega: config.zoomOmega, dt: dt
            )

            keyframes.append(ZoomKeyframe(
                time: t, focusX: camX, focusY: camY, zoom: camZoom
            ))
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
