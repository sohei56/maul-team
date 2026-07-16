//
// MaulTeam for Mac
// Copyright (c) 2026 sohei56. All rights reserved.
//
// Source-available; NOT covered by this repository's MIT License.
// See macapp/LICENSE for terms.
//
// dmg-background.swift — render the dmg installer background at build time.
//
// Usage: swift dmg-background.swift <outdir>
// Writes bg.png (660x420) and bg@2x.png (1320x840); make-dmg.sh combines them
// into a retina-aware TIFF via `tiffutil -cathidpicheck`.
//
// CoreGraphics + CoreText + ImageIO only — an offscreen CGBitmapContext needs
// no WindowServer, so this runs headless (CI) by construction. Do not add
// AppKit drawing (NSImage.lockFocus etc.) here.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Canvas in points; must match the window bounds make-dmg.sh sets via Finder.
let canvasW: CGFloat = 660
let canvasH: CGFloat = 420

// Icon-slot centers in Finder window coordinates (origin top-left) — must
// match the `set position of item …` values in make-dmg.sh.
let iconY: CGFloat = 185
let appX: CGFloat = 165
let appsX: CGFloat = 495
let slotRadius: CGFloat = 76

func color(_ white: CGFloat, _ alpha: CGFloat) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceGray(), components: [white, alpha])!
}

func render(scale: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil,
        width: Int(canvasW * scale),
        height: Int(canvasH * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)

    // CG origin is bottom-left; convert the top-left slot coordinates once.
    let slotY = canvasH - iconY

    // Light backdrop (Orca-style): Finder draws icon labels in black whenever
    // a background picture is set, regardless of system appearance, so the
    // background must be light for the labels to stay readable.
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),
            CGColor(srgbRed: 0.902, green: 0.902, blue: 0.918, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvasH),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Left slot (the app): a subtle filled disc so the icon has a stage.
    ctx.setFillColor(color(0.0, 0.05))
    ctx.fillEllipse(in: CGRect(
        x: appX - slotRadius, y: slotY - slotRadius,
        width: slotRadius * 2, height: slotRadius * 2))

    // Right slot (Applications): dashed drop-target ring, Orca-style.
    ctx.setStrokeColor(color(0.0, 0.35))
    ctx.setLineWidth(2)
    ctx.setLineDash(phase: 0, lengths: [7, 5])
    ctx.strokeEllipse(in: CGRect(
        x: appsX - slotRadius, y: slotY - slotRadius,
        width: slotRadius * 2, height: slotRadius * 2))

    // Dashed arrow between the slots, arrowhead pointing right.
    let arrowStart = appX + slotRadius + 14
    let headTip = appsX - slotRadius - 14
    let headLength: CGFloat = 22
    ctx.setStrokeColor(color(0.30, 0.9))
    ctx.setLineWidth(4)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [10, 8])
    ctx.move(to: CGPoint(x: arrowStart, y: slotY))
    ctx.addLine(to: CGPoint(x: headTip - headLength - 4, y: slotY))
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setFillColor(color(0.30, 0.9))
    ctx.move(to: CGPoint(x: headTip, y: slotY))
    ctx.addLine(to: CGPoint(x: headTip - headLength, y: slotY + 13))
    ctx.addLine(to: CGPoint(x: headTip - headLength, y: slotY - 13))
    ctx.closePath()
    ctx.fillPath()

    // Caption under the slots.
    let font = CTFontCreateUIFontForLanguage(.system, 15, nil)!
    let caption = NSAttributedString(
        string: "Drag MaulTeam to Applications to install",
        attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color(0.15, 0.85),
        ])
    let line = CTLineCreateWithAttributedString(caption)
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    ctx.textPosition = CGPoint(x: (canvasW - textWidth) / 2, y: canvasH - 330)
    CTLineDraw(line, ctx)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL, dpi: CGFloat) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ]
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("failed to write \(url.path)")
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift dmg-background.swift <outdir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

writePNG(render(scale: 1), to: outDir.appendingPathComponent("bg.png"), dpi: 72)
writePNG(render(scale: 2), to: outDir.appendingPathComponent("bg@2x.png"), dpi: 144)
print("wrote \(outDir.path)/bg.png and bg@2x.png")
