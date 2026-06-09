#!/usr/bin/env swift
//
//  GenerateAppIcon.swift
//  loopRecording
//
//  Renders the app icon with CoreGraphics and writes the three iOS
//  appearance variants (light / dark / tinted) into the asset catalog.
//
//  Concept: a ring of vibrant, glossy rounded tiles arranged in a loop
//  around a red record block — a "loop" built from colourful blocks on a
//  dark rounded canvas.
//
//  Usage:  swift Tools/GenerateAppIcon.swift
//

import Foundation
import CoreGraphics
import ImageIO

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// MARK: - Geometry / config

let finalSize = 1024            // exported pixel size
let scale = 3                   // supersample factor while drawing
let work = finalSize * scale    // working canvas size

let assetDir = "loopRecording/Assets.xcassets/AppIcon.appiconset"

// MARK: - Small helpers

typealias RGB = (r: Double, g: Double, b: Double)

func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
    (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
}

func cg(_ c: RGB, _ a: Double = 1) -> CGColor {
    CGColor(red: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(a))
}

func u8(_ r: Int, _ g: Int, _ b: Int) -> RGB {
    (Double(r) / 255, Double(g) / 255, Double(b) / 255)
}

func makeContext(_ size: Int) -> CGContext {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func rad(_ deg: Double) -> Double { deg * Double.pi / 180 }

func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let hh = (h.truncatingRemainder(dividingBy: 360) + 360)
        .truncatingRemainder(dividingBy: 360) / 60
    let c = v * s
    let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    let rgb: RGB
    switch Int(hh) {
    case 0: rgb = (c, x, 0)
    case 1: rgb = (x, c, 0)
    case 2: rgb = (0, c, x)
    case 3: rgb = (0, x, c)
    case 4: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return (rgb.r + m, rgb.g + m, rgb.b + m)
}

// MARK: - Drawing primitives

/// Flat, matte background — a solid fill with at most a very subtle, even
/// tonal shift (no glossy hotspots).
func fillBackground(_ ctx: CGContext, top: RGB, bottom: RGB) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let colors = [cg(top), cg(bottom)] as CFArray
    let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
    let w = CGFloat(ctx.width)
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 0, y: w),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
}

func fillBackgroundSolid(_ ctx: CGContext, _ c: RGB) {
    ctx.setFillColor(cg(c))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
}

/// A single glossy rounded tile: soft drop shadow, vertical gradient
/// (lighter top → base bottom) and a faint top highlight.
func drawTile(_ ctx: CGContext, center: CGPoint, size: Double, base: RGB,
              gloss: Bool = true, shadow: Bool = true, alpha: Double = 1) {
    let s = CGFloat(size)
    let r = s * 0.30
    let rect = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
    let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    let cs = CGColorSpaceCreateDeviceRGB()

    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.06),
                      blur: CGFloat(size * 0.16), color: cg((0, 0, 0), 0.45 * alpha))
        ctx.addPath(path)
        ctx.setFillColor(cg(base, alpha))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Body gradient (top brighter, bottom slightly deeper) for a soft sheen.
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let top = lerp(base, (1, 1, 1), 0.22)
    let bot = lerp(base, (0, 0, 0), 0.18)
    let grad = CGGradient(colorsSpace: cs,
                          colors: [cg(top, alpha), cg(base, alpha), cg(bot, alpha)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: center.x, y: center.y + s / 2),
                           end: CGPoint(x: center.x, y: center.y - s / 2),
                           options: [])
    if gloss {
        // Faint highlight band across the upper portion.
        let hRect = CGRect(x: rect.minX, y: center.y + s * 0.06,
                           width: s, height: s * 0.44)
        let hl = CGGradient(colorsSpace: cs,
                            colors: [cg((1, 1, 1), 0.28 * alpha), cg((1, 1, 1), 0)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(hl,
                               start: CGPoint(x: center.x, y: hRect.maxY),
                               end: CGPoint(x: center.x, y: hRect.minY),
                               options: [])
    }
    ctx.restoreGState()
}

/// Tiles sweeping clockwise around an arc with a gap — a spinner/comet that
/// reads as continuous looping motion. Tiles grow and gain opacity toward
/// the leading "head"; a small arrowhead tile marks the direction.
/// `f` runs 0 (tail) → 1 (head); `colorFn(f)` picks each tile's colour.
func drawTileSpinner(_ ctx: CGContext, count: Int, sweepDeg: Double,
                     colorFn: (Double) -> RGB) {
    let c = Double(work) / 2
    let radius = Double(work) * 0.320
    let maxTile = Double(work) * 0.150
    let minTile = Double(work) * 0.090
    // Head sits just before the top gap; sweep runs clockwise (decreasing
    // angle) back to the tail on the other side of the gap.
    let headDeg = 90 - (360 - sweepDeg) / 2
    for i in 0..<count {
        let f = count == 1 ? 1 : Double(i) / Double(count - 1)   // 0 tail → 1 head
        let deg = headDeg - (1 - f) * sweepDeg
        let ang = rad(deg)
        let px = c + radius * cos(ang)
        let py = c + radius * sin(ang)
        // Gentle size taper + a strong opacity trail — the iOS-spinner
        // language that reads unmistakably as looping motion.
        let size = minTile + (maxTile - minTile) * f
        let alpha = 0.30 + 0.70 * f
        drawTile(ctx, center: CGPoint(x: px, y: py), size: size,
                 base: colorFn(f), alpha: alpha)
    }
}

/// Central record block — a glossy red rounded tile, larger than the loop
/// tiles so it reads as the focal "record" element.
func drawRecordBlock(_ ctx: CGContext, base: RGB) {
    let c = Double(work) / 2
    drawTile(ctx, center: CGPoint(x: c, y: c), size: Double(work) * 0.265, base: base)
}

// MARK: - Export

func downscaleAndWrite(_ image: CGImage, to path: String) {
    let ctx = makeContext(finalSize)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: finalSize, height: finalSize))
    let out = ctx.makeImage()!

    let url = URL(fileURLWithPath: path)
    let type: CFString
    #if canImport(UniformTypeIdentifiers)
    type = UTType.png.identifier as CFString
    #else
    type = "public.png" as CFString
    #endif
    let dest = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)!
    CGImageDestinationAddImage(dest, out, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

// MARK: - Variants

// Vibrant hue cycle around the loop (purple → blue → cyan → green → pink).
func loopHue(_ f: Double) -> RGB { hsv(265 + f * 300, 0.72, 0.95) }

func buildDefault() -> CGImage {
    let ctx = makeContext(work)
    fillBackground(ctx, top: u8(46, 38, 66), bottom: u8(22, 18, 34))
    drawTileSpinner(ctx, count: 8, sweepDeg: 300, colorFn: loopHue)
    drawRecordBlock(ctx, base: u8(230, 52, 46))
    return ctx.makeImage()!
}

func buildDark() -> CGImage {
    let ctx = makeContext(work)
    fillBackground(ctx, top: u8(22, 19, 33), bottom: u8(8, 7, 13))
    drawTileSpinner(ctx, count: 8, sweepDeg: 300, colorFn: loopHue)
    drawRecordBlock(ctx, base: u8(214, 46, 40))
    return ctx.makeImage()!
}

func buildTinted() -> CGImage {
    // Grayscale luminance on black; iOS applies the user's tint.
    let ctx = makeContext(work)
    fillBackgroundSolid(ctx, u8(0, 0, 0))
    drawTileSpinner(ctx, count: 8, sweepDeg: 300) { f in
        let v = 0.55 + 0.35 * f
        return (v, v, v)
    }
    drawRecordBlock(ctx, base: u8(225, 225, 225))
    return ctx.makeImage()!
}

// MARK: - Run

downscaleAndWrite(buildDefault(), to: "\(assetDir)/image 1.png")
downscaleAndWrite(buildDark(),    to: "\(assetDir)/image 2.png")
downscaleAndWrite(buildTinted(),  to: "\(assetDir)/image.png")
print("Icon generation complete.")
