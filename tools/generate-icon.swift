#!/usr/bin/env swift
// Generate the macOS app icon programmatically.
//
// Design:
//   • 1024×1024 squircle (~22.5% corner radius)
//   • Indigo → violet linear gradient background
//   • Subtle radial highlight for depth
//   • White Locus loop ~56% of the canvas with a soft drop shadow
//
// This script writes the 1024×1024 master PNG; sips downsamples to all
// other appiconset sizes.

import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

let canvasSize: CGFloat = 1024
let outputURL = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
let logoURL = URL(fileURLWithPath: "Resources/Assets.xcassets/LocusLogo.imageset/locus@3x.png")

// MARK: - Recolor source logo (black-on-light → white-on-transparent)

func whiteSilhouette(of url: URL) -> CGImage {
    guard let nsImage = NSImage(contentsOf: url),
          let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Could not load \(url.path)")
    }
    let ci = CIImage(cgImage: cg)
    // Steep luminance → alpha mapping. Pixels with luminance > ~0.5 collapse
    // to alpha 0 (transparent BG), pixels with luminance < ~0.5 collapse to
    // alpha 1 (white logo). Equivalent to:  α = clamp((0.5 − lum) · gain + 0.5).
    let gain: CGFloat = 10
    let matrix = ci.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0,             y: 0,             z: 0,             w: 0),
        "inputGVector": CIVector(x: 0,             y: 0,             z: 0,             w: 0),
        "inputBVector": CIVector(x: 0,             y: 0,             z: 0,             w: 0),
        "inputAVector": CIVector(x: -0.30 * gain,  y: -0.59 * gain,  z: -0.11 * gain,  w: 0),
        "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0.5 * gain + 0.5)
    ]).cropped(to: ci.extent)  // bias makes the unbounded outside non-zero
    guard let result = CIContext().createCGImage(matrix, from: ci.extent) else {
        fatalError("createCGImage failed")
    }
    return result
}

// MARK: - Compose

let space = CGColorSpaceCreateDeviceRGB()
// CGContext for 32-bit RGBA needs an explicit byte-order paired with the
// alpha info — premultipliedLast + byteOrder32Big gives R-G-B-A in memory.
let bitmapInfo: UInt32 =
    CGImageAlphaInfo.premultipliedLast.rawValue |
    CGBitmapInfo.byteOrder32Big.rawValue

guard let context = CGContext(
    data: nil,
    width: Int(canvasSize), height: Int(canvasSize),
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: bitmapInfo
) else {
    fatalError("CGContext init returned nil")
}

// Squircle clip
let cornerRadius = canvasSize * 0.225
let rect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
context.addPath(CGPath(roundedRect: rect,
                       cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                       transform: nil))
context.clip()

// Background gradient (indigo → violet, top-down)
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.36, green: 0.30, blue: 0.92, alpha: 1),  // #5C4DEB
    CGColor(red: 0.62, green: 0.30, blue: 0.86, alpha: 1)   // #9E4DDC
] as CFArray, locations: [0, 1])!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: canvasSize),
    end:   CGPoint(x: 0, y: 0),
    options: []
)

// Highlight on the upper-left for a "lit" feel
let highlight = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0)
] as CFArray, locations: [0, 1])!
context.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: canvasSize * 0.30, y: canvasSize * 0.85), startRadius: 0,
    endCenter:   CGPoint(x: canvasSize * 0.30, y: canvasSize * 0.85), endRadius: canvasSize * 0.55,
    options: []
)

// Locus loop with shadow
let logo = whiteSilhouette(of: logoURL)
let logoSize = canvasSize * 0.56
let logoRect = CGRect(
    x: (canvasSize - logoSize) / 2,
    y: (canvasSize - logoSize) / 2,
    width: logoSize, height: logoSize
)
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -canvasSize * 0.012),
    blur: canvasSize * 0.025,
    color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30)
)
context.draw(logo, in: logoRect)
context.restoreGState()

// MARK: - Save

guard let cgImage = context.makeImage() else { fatalError("makeImage failed") }
guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
) else { fatalError("Could not open destination") }
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG finalize failed") }
print("✓ wrote \(outputURL.path)")
