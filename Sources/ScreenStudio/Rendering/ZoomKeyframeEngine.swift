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
/// Zoom *breathes*: push in when the user commits to a spot (click / typing),
/// hold while they work, pull back to full frame when they move on. Focus
/// follows the cursor the way a game camera does — through a **deadzone**:
/// while the cursor roams the comfortable middle of the visible viewport the
/// camera is perfectly planted; only when the cursor presses past the
/// deadzone edge does the camera glide along to keep it framed. The result is
/// deliberate, not twitchy.
///
///   **Pass 1 — plan zoom segments.**
///   1. Interaction anchors are grouped into *clusters*: clicks set the
///      cluster position; typing, scrolling and dragging keep it alive.
///   2. Clusters become *segments* — push in just before the first anchor
///      (anticipation), hold through the last anchor plus `zoomHold`, pull
///      back after. Near segments merge into one shot; far jumps pull back
///      to full frame first so the viewer can re-orient.
///
///   **Pass 2 — render the curve.**
///   3. Cursor positions are resampled per frame (interpolating only across
///      gaps ≤ `maxInterpolationGap` — longer silences mean the mouse sat
///      still, so hold) and low-passed to strip OS jitter.
///   4. Deadzone follow picks the focus target; **critically damped springs**
///      glide focus + zoom to their targets with no overshoot, and focus is
///      clamped so the viewport never crosses the video edge.
///   5. Typing is pinned: keyDown events keep a segment alive but carry no
///      position, so the camera holds on the field the user last clicked.
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
        var zoomHold: Double = 1.8
        /// Segments separated by less than this merge into one zoomed shot…
        var mergeGap: Double = 1.6
        /// …but only if their anchors are within this fraction of the
        /// diagonal. Farther jumps pull back to full frame between segments.
        var panRadiusFraction: Double = 0.40

        // ── Follow behavior ──────────────────────────────────────────────
        /// Fraction of the visible viewport (around its center) where the
        /// cursor can roam without moving the camera. 0 = always follow,
        /// 1 = never follow until the cursor hits the viewport edge.
        var followDeadzoneFraction: Double = 0.5
        /// Position events farther apart than this are bridged by holding,
        /// not interpolating — a silent gap means the mouse sat still.
        var maxInterpolationGap: Double = 0.25
        /// Time-constant of the raw-mouse low-pass filter, in seconds.
        var mouseLowPassTau: Double = 0.030

        // ── Curve rendering ──────────────────────────────────────────────
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
        let width = Double(videoSize.width)
        let height = Double(videoSize.height)
        let centerX = width / 2
        let centerY = height / 2
        let sortedEvents = events.sorted { $0.time < $1.time }

        let segments = planSegments(
            events: sortedEvents,
            videoSize: videoSize,
            fallbackFocus: CGPoint(x: centerX, y: centerY)
        )

        // ── Per-frame cursor positions (resample + low-pass) ─────────────
        let posEvents = sortedEvents.filter { $0.kind != .keyDown }

        var rawX = [Double](repeating: centerX, count: frameCount)
        var rawY = [Double](repeating: centerY, count: frameCount)

        if let first = posEvents.first {
            var pi = 0
            for f in 0..<frameCount {
                let t = Double(f) * dt
                if t < first.time {
                    // Hold the first position so the camera doesn't sweep in.
                    rawX[f] = first.x
                    rawY[f] = first.y
                    continue
                }
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

            let alpha = dt / (config.mouseLowPassTau + dt)
            var fx = rawX[0]
            var fy = rawY[0]
            for f in 0..<frameCount {
                fx += alpha * (rawX[f] - fx)
                fy += alpha * (rawY[f] - fy)
                rawX[f] = fx
                rawY[f] = fy
            }
        }

        // ── Springs against deadzone-follow targets ──────────────────────
        var camX: Double = centerX
        var camY: Double = centerY
        var camVX: Double = 0
        var camVY: Double = 0
        var camZoom = config.idleZoom
        var camZoomV: Double = 0

        // Where the camera *wants* to rest. Moves only when the cursor
        // pushes past the deadzone edge.
        var followX = centerX
        var followY = centerY
        var wasInSegment = false

        var keyframes = [ZoomKeyframe]()
        keyframes.reserveCapacity(frameCount)

        var si = 0
        for f in 0..<frameCount {
            let t = Double(f) * dt
            while si < segments.count && segments[si].end < t { si += 1 }
            let inSegment = si < segments.count && t >= segments[si].start

            var targetZoom = config.idleZoom
            var targetX = centerX
            var targetY = centerY

            if inSegment {
                targetZoom = config.activeZoom

                if !wasInSegment {
                    // Entering a shot: frame the cluster anchor directly.
                    followX = segments[si].anchorX
                    followY = segments[si].anchorY
                }

                // Deadzone follow, sized by the *visible* viewport at the
                // target zoom so behavior doesn't change mid-transition.
                let halfVisW = width / (2 * config.activeZoom)
                let halfVisH = height / (2 * config.activeZoom)
                let deadW = halfVisW * config.followDeadzoneFraction
                let deadH = halfVisH * config.followDeadzoneFraction

                let errX = rawX[f] - followX
                let errY = rawY[f] - followY
                if abs(errX) > deadW {
                    followX += errX - (errX > 0 ? deadW : -deadW)
                }
                if abs(errY) > deadH {
                    followY += errY - (errY > 0 ? deadH : -deadH)
                }

                targetX = followX
                targetY = followY
            }
            wasInSegment = inSegment

            // Keep the zoom viewport inside the video so a focus near a
            // corner doesn't expose black margins.
            let clampZoom = max(1.0, camZoom)
            let halfW = width / (2 * clampZoom)
            let halfH = height / (2 * clampZoom)
            targetX = min(width - halfW, max(halfW, targetX))
            targetY = min(height - halfH, max(halfH, targetY))

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
                time: t,
                focusX: min(width - halfW, max(halfW, camX)),
                focusY: min(height - halfH, max(halfH, camY)),
                zoom: camZoom
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
        /// Where the shot opens — the first cluster's anchor.
        var anchorX: Double
        var anchorY: Double
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

            // Clicks place the cluster anchor; everything else only keeps
            // the cluster alive so the zoom doesn't release mid-interaction.
            let positionAnchor: CGPoint?
            let extendsOnly: Bool
            switch e.kind {
            case .leftDown, .rightDown:
                positionAnchor = CGPoint(x: e.x, y: e.y)
                extendsOnly = false
            case .leftUp, .rightUp, .dragged, .scroll:
                positionAnchor = CGPoint(x: e.x, y: e.y)
                extendsOnly = true
            case .keyDown:
                positionAnchor = nil
                extendsOnly = true
            case .move:
                continue
            }

            if var c = clusters.last, e.time - c.end <= config.clusterGapTime,
               extendsOnly
                || positionAnchor.map({ hypot($0.x - c.cx, $0.y - c.cy) <= clusterRadius }) ?? true {
                c.end = e.time
                if let p = positionAnchor, !extendsOnly {
                    c.cx = (c.cx * c.weight + p.x) / (c.weight + 1)
                    c.cy = (c.cy * c.weight + p.y) / (c.weight + 1)
                    c.weight += 1
                }
                clusters[clusters.count - 1] = c
            } else {
                let p = positionAnchor ?? lastCursor
                clusters.append(Cluster(start: e.time, end: e.time,
                                        cx: p.x, cy: p.y, weight: 1))
            }
        }

        // ── Merge clusters into segments ─────────────────────────────────
        var segments = [Segment]()
        var lastAnchor = fallbackFocus
        for c in clusters {
            let start = max(0, c.start - config.anticipation)
            let end = c.end + config.zoomHold
            if var last = segments.last,
               start - last.end <= config.mergeGap,
               hypot(c.cx - lastAnchor.x, c.cy - lastAnchor.y) <= panRadius {
                // Near in time and space — stay zoomed; deadzone follow will
                // carry the camera to the new spot.
                last.end = max(last.end, end)
                segments[segments.count - 1] = last
            } else {
                // A far jump that overlaps the previous segment's hold tail:
                // trim the tail so the zoom dips toward full frame between
                // the two locations and the viewer can re-orient.
                if var lastSeg = segments.last, lastSeg.end > start {
                    lastSeg.end = start
                    segments[segments.count - 1] = lastSeg
                }
                segments.append(Segment(start: start, end: end,
                                        anchorX: c.cx, anchorY: c.cy))
            }
            lastAnchor = CGPoint(x: c.cx, y: c.cy)
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
