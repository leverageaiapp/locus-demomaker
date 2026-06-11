# Locus DemoMaker

A native macOS screen recorder that produces polished demo videos with
**cursor-following auto-zoom**, an optional **circular presenter bubble**,
and **click ripples** — inspired by [screen.studio](https://screen.studio/).

Designed to be the fastest path from "press record" to a publishable clip.
No editor, no timeline, no fuss.

<p>
  <a href="https://github.com/leverageaiapp/locus-demomaker/releases/latest">
    <img alt="latest release" src="https://img.shields.io/github/v/release/leverageaiapp/locus-demomaker?label=download&color=blue">
  </a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-lightgrey">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-orange">
</p>

---

## Download

Grab the latest **`.dmg`** from
[Releases](https://github.com/leverageaiapp/locus-demomaker/releases/latest),
drag **Locus DemoMaker** into Applications, launch.

> Builds aren't notarized yet, so on first launch macOS will say
> *"Locus DemoMaker can't be opened because Apple cannot check it for malicious
> software."* Right-click → **Open** to bypass once.

On first launch you'll be prompted for these system permissions:

| Permission | Why |
|------------|-----|
| **Screen Recording** | Required by ScreenCaptureKit. |
| **Accessibility**    | Global mouse + key event tap (cursor tracking, typing-aware focus). |
| **Microphone**       | Audio narration captured alongside video. |
| **Camera** (optional) | Circular presenter bubble in the corner of the final video. |

---

## What it does

### Three capture modes
- **Screen** — record the whole display.
- **Window** — hover-to-highlight overlay; click the window you want.
  Recording follows the window if it moves.
- **Region** — drag a rectangle on the screen; defaults to the topmost
  window's bounds so the common case is one click. The selection is
  remembered across launches.

### Auto-zoom that knows when you're typing
Records a 60 fps source video plus every mouse + key event. At export time,
clicks, drags, scrolls and key presses are grouped into **interaction
clusters** — events close together in time and screen space — and each cluster
becomes a planned zoom segment: push in just before the first click
(anticipation), hold while you work, pull back to full frame when you move on.
Nearby segments merge into one continuous shot that pans with the cursor;
far jumps pull back first so the viewer can re-orient. Critically damped
springs drive both pan and zoom, so nothing ever overshoots. **Key presses
keep a segment alive but don't move the focus** — so when you start typing in
an input field, the camera holds on that field instead of drifting back to
screen center.

### Optional presenter bubble
Toggle on the camera and a circular sidecar webcam recording is composited
into the final video at a fixed corner — *after* the screen zoom transform,
so the bubble stays rock-still while the screen pans behind it.

### Two export visual modes
- **Auto Zoom** — cursor-following pan/zoom (the default).
- **Full Frame** — static screen, click ripples + camera bubble only.
  For when you want zero camera movement.

### Recording library
Past recordings live in a list inside the app:
**Export** them to mp4, **Show in Finder**, **re-export** with different
settings, or **Move to Trash**. Once exported, the row remembers the output
path across app restarts.

---

## Architecture

```
record  ─►  source.mp4 + camera.mp4 + metadata.json  ─►  render  ─►  final.mp4
```

| Stage          | Component                                  | Tech                                       |
|----------------|--------------------------------------------|--------------------------------------------|
| Screen capture | `Recording/ScreenRecorder.swift`           | ScreenCaptureKit + AVAssetWriter (H.264)   |
| Window picker  | `Recording/WindowPicker.swift`             | NSVisualEffectView overlay + CGWindowList  |
| Region picker  | `Recording/RegionSelector.swift`           | Translucent NSWindow + drag/resize hit-test |
| Camera capture | `Recording/CameraRecorder.swift`           | AVCaptureSession (sidecar mp4)             |
| Mouse + keys   | `Recording/MouseTracker.swift`             | CGEventTap (`cgSessionEventTap`)           |
| Permissions    | `Recording/PermissionsManager.swift`       | TCC probes + System Settings deep-links    |
| Auto-zoom math | `Rendering/ZoomKeyframeEngine.swift`       | Activity signal + critically-damped spring |
| Compositor     | `Rendering/AutoZoomCompositor.swift`       | Custom `AVVideoCompositing` + Core Image   |
| Cursor render  | `Rendering/CursorRenderer.swift`           | Re-rendered crisp cursor + click ripples   |
| Export         | `Rendering/VideoExporter.swift`            | `AVAssetExportSession` w/ custom compositor |

Everything is **post-processed**. Recording captures native pixels at 60 fps;
the auto-zoom curve is applied frame-by-frame at export. Keeps recording
cheap and the final result perfectly smooth.

### Auto-zoom algorithm

See `ZoomKeyframeEngine.swift`. Briefly:

1. **Activity signal** — clicks (+1.0), scrolls (+0.6), key presses (+0.55),
   and fast cursor moves contribute impulses; impulses decay exponentially
   (half-life ≈ 1.2 s).
2. **Anticipation** — small forward look so zoom rises *before* a click,
   not after.
3. **Targets** — `zoom = lerp(idle, active, activity)`. Focus follows the
   cursor when active, but **key presses don't move the focus**, so typing
   pins the camera on the last clicked input field.
4. **Smoothing pipeline** — sub-frame interpolation between events → IIR
   low-pass on the resampled position (τ ≈ 30 ms) → critically damped spring
   on focus (ω ≈ 5.5) and zoom (ω ≈ 3.0). No overshoot, no twitching, no
   rubber-banding when activity briefly dips.
5. **Hysteresis idle detection** — the focus only re-centers after activity
   stays below threshold for 0.8 s straight; brief lulls don't cause snap-backs.

---

## Build from source

Requires macOS 14+, Xcode 15+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
./setup.sh                 # generates ScreenStudio.xcodeproj from project.yml
open ScreenStudio.xcodeproj
```

`./setup.sh` auto-detects an Apple Development cert in your keychain and
configures the project for stable Apple Development signing — that way macOS
TCC remembers Screen Recording / Accessibility / Mic / Camera grants across
rebuilds. Without it, ad-hoc signing changes the cdhash on every build and
you'd have to re-grant every permission each time.

### Build a DMG locally

```sh
./scripts/build-dmg.sh
# → build/dmg/Locus-DemoMaker.dmg
```

### Cut a release

```sh
git tag v0.6.0
git push origin v0.6.0
```

The `Release` GitHub Actions workflow runs on `macos-14`, builds an unsigned
DMG, attaches it to a fresh GitHub Release, and adds a SHA-256 checksum.
(Notarized signing on CI is on the roadmap.)

---

## Project layout

```
Sources/ScreenStudio/
├── App/                 — SwiftUI entry point
├── Models/              — capture mode, recording metadata, list items, mouse events
├── Recording/           — capture pipeline (screen + window + region + camera + mouse + permissions + library)
├── Rendering/           — keyframe engine, custom compositor, cursor renderer, exporter
├── UI/                  — SwiftUI views (hero card, recordings list, permissions screen)
├── Info.plist
└── ScreenStudio.entitlements
Resources/Assets.xcassets/
├── AppIcon.appiconset/  — programmatically generated by tools/generate-icon.swift
└── LocusLogo.imageset/  — brand mark used in the welcome screen
tools/
└── generate-icon.swift  — re-renders the app icon
scripts/
└── build-dmg.sh         — Release build → drag-to-install DMG
```

Recordings land in `~/Movies/ScreenStudio/Recording-<timestamp>/` containing:

- `source.mp4` — the raw screen capture
- `camera.mp4` *(optional)* — sidecar webcam recording
- `metadata.json` — mouse + key event timeline, capture mode, frame rate,
  display geometry, camera overlay placement, recording quality
- `export.json` *(optional)* — pointer to the most recently exported file

Final exports go wherever you choose in the save panel.

---

## Roadmap

- Developer ID signing + notarization for distributed DMGs
- Custom cursor styles
- Segment-based zoom presets (e.g. pin across multiple clicks on the same area)
- Background blur / replacement for the camera bubble
- System audio capture
