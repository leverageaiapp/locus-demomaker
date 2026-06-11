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
/// Two-pass design — because export is offline we can read the whole event
/// stream before deciding anything, like an editor planning camera moves:
///
///   **Pass 1 — plan zoom segments.**
///   1. Interaction anchors (clicks, drags, scrolls, key presses) are grouped
///      into *clusters*: events close together in time AND screen space.
///      Key presses extend a cluster in time but carry no position.
///   2. Clusters become *segments* — push in just before the first anchor
///      (anticipation), hold through the last anchor plus `zoomHold`, pull
///      back to full frame after. Neighboring segments whose focuses are
///      near each other merge into one continuous zoomed shot (the camera
///      pans); far-apart jumps instead get a brief pull-back so the viewer
///      can re-orient.
///
///   **Pass 2 — render the curve.**
///   3. Sub-frame **position resampling** with linear interpolation between
///      adjacent mouse-position events, then an **IIR low-pass** to take the
///      edge off OS mouse jitter.
///   4. **Critically damped springs** for focus + zoom — no overshoot. Zoom
///      target is binary (full frame or `activeZoom`); the spring turns the
///      step into a clean push-in/pull-out instead of a continuous "breathing"
///      tied to instantaneous activity.
///   5. Typing is **pinned to the last click position**: keyDown events keep
///      the segment alive but do *not* update the position target, so the
///      camera holds on whatever input field the user last clicked.
struct ZoomKeyframeEngine {
    struct Config {
        var idleZoom: Double = 1.0
        var activeZoom: Double = 1.45

        // ── Cluster detection ────────────────────────────────────────────
        /// Max silence between anchors that still counts as the same cluster.
        var clusterGapTime: Double = 2.5
        /// Same-cluster spatial bound, as a fraction of the video diagonal.
        var clusterRadiusFraction: Double = 0.18

        // ── Segment planning ─────────────────────────────────────────────
        /// Zoom starts this long before a cluster's first anchor.
        var anticipation: Double = 0.4
        /// Zoom is held this long after a cluster's last anchor.
        var zoomHold: Double = 1.4
        /// Segments separated by less than this merge into one zoomed shot…
        var mergeGap: Double = 1.6
        /// …but only if their focuses are within this fraction of the
        /// diagonal. Farther jumps pull back to full frame between segments.
        var panRadiusFraction: Double = 0.40

        // ── Curve rendering ──────────────────────────────────────────────
        /// Position events farther apart than this are bridged by holding,
        /// not interpolating — a silent gap means the mouse sat still, and
        /// lerping across it would leak the next position into the past.
        var maxInterpolationGap: Double = 0.25
        /// Time-constant of the raw-mouse low-pass filter, in seconds.
        var mouseLowPassTau: Double = 0.030
        /// Spring natural frequency for focus tracking (rad/s). Higher = snappier.
        var focusOmega: Double = 5.5
        /// Spring natural frequency for zoom tracking (rad/s). Lower = smoother zoom.
        var zoomOmega: Double = 3.0
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

        let segments = planSegments(
            events: sortedEvents,
            videoSize: videoSize,
            fallbackFocus: CGPoint(x: centerX, y: centerY)
        )

        // ── Sub-frame position resampling ────────────────────────────────
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
                    if span <= config.maxInterpolationGap {
                        let r = min(1, max(0, (t - p0.time) / span))
                        rawX[f] = p0.x + (p1.x - p0.x) * r
                        rawY[f] = p0.y + (p1.y - p0.y) * r
                    } else {
                        // The mouse sat still through this gap — hold.
                        rawX[f] = p0.x
                        rawY[f] = p0.y
                    }
                } else {
                    rawX[f] = p0.x
                    rawY[f] = p0.y
                }
            }
        }

        // ── IIR low-pass on the raw position ─────────────────────────────
        let alpha = dt / (config.mouseLowPassTau + dt)
        var fx = rawX[0]
        var fy = rawY[0]
        for f in 0..<frameCount {
            fx += alpha * (rawX[f] - fx)
            fy += alpha * (rawY[f] - fy)
            rawX[f] = fx
            rawY[f] = fy
        }

        // ── Spring-driven keyframes against the segment plan ─────────────
        var camX: Double = centerX
        var camY: Double = centerY
        var camVX: Double = 0
        var camVY: Double = 0
        var camZoom = config.idleZoom
        var camZoomV: Double = 0

        var keyframes = [ZoomKeyframe]()
        keyframes.reserveCapacity(frameCount)

        var si = 0
        for f in 0..<frameCount {
            let t = Double(f) * dt
            while si < segments.count && segments[si].end < t { si += 1 }
            let inSegment = si < segments.count && t >= segments[si].start

            let targetZoom = inSegment ? config.activeZoom : config.idleZoom
            let targetX: Double = inSegment ? rawX[f] : centerX
            let targetY: Double = inSegment ? rawY[f] : centerY

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

    // MARK: - Pass 1: segment planning

    private struct Cluster {
        var start: Double
        var end: Double
        var cx: Double
        var cy: Double
        var weight: Double
    }

    private struct Segment {
        var start: Double
        var end: Double
        var cx: Double
        var cy: Double
    }

    private func planSegments(events: [MouseEvent], videoSize: CGSize,
                              fallbackFocus: CGPoint) -> [Segment] {
        let diagonal = Double(hypot(videoSize.width, videoSize.height))
        let clusterRadius = diagonal * config.clusterRadiusFraction
        let panRadius = diagonal * config.panRadiusFraction

        // ── Group anchors into clusters ──────────────────────────────────
        var clusters = [Cluster]()
        var lastCursor = fallbackFocus

        for e in events {
            // Track the latest known cursor position so a typing-only burst
            // (keyboard shortcut, no preceding click) anchors where the
            // cursor is actually resting.
            if e.kind != .keyDown {
                lastCursor = CGPoint(x: e.x, y: e.y)
            }

            let anchorPos: CGPoint?
            switch e.kind {
            case .leftDown, .leftUp, .rightDown, .rightUp, .dragged, .scroll:
                anchorPos = CGPoint(x: e.x, y: e.y)
            case .keyDown:
                anchorPos = nil // extends a cluster in time, not in space
            case .move:
                continue // plain movement never starts or extends a zoom
            }

            if var c = clusters.last,
               e.time - c.end <= config.clusterGapTime,
               anchorPos.map({ hypot($0.x - c.cx, $0.y - c.cy) <= clusterRadius }) ?? true {
                c.end = e.time
                if let p = anchorPos {
                    c.cx = (c.cx * c.weight + p.x) / (c.weight + 1)
                    c.cy = (c.cy * c.weight + p.y) / (c.weight + 1)
                    c.weight += 1
                }
                clusters[clusters.count - 1] = c
            } else {
                let p = anchorPos ?? lastCursor
                clusters.append(Cluster(start: e.time, end: e.time,
                                        cx: p.x, cy: p.y, weight: 1))
            }
        }

        // ── Merge clusters into segments ─────────────────────────────────
        var segments = [Segment]()
        for c in clusters {
            let start = max(0, c.start - config.anticipation)
            let end = c.end + config.zoomHold
            if var last = segments.last,
               start - last.end <= config.mergeGap,
               hypot(c.cx - last.cx, c.cy - last.cy) <= panRadius {
                // Near in time and space — stay zoomed and pan across.
                last.end = max(last.end, end)
                last.cx = c.cx
                last.cy = c.cy
                segments[segments.count - 1] = last
            } else {
                // A far jump that overlaps the previous segment's hold tail:
                // trim the tail so the zoom dips toward full frame between
                // the two locations and the viewer can re-orient.
                if var last = segments.last, last.end > start {
                    last.end = start
                    segments[segments.count - 1] = last
                }
                segments.append(Segment(start: start, end: end, cx: c.cx, cy: c.cy))
            }
        }

        return segments
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
