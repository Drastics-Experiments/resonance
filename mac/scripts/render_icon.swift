#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Darwin
import Foundation

private let canvasSize = 1024

private func color(_ red: Int, _ green: Int, _ blue: Int, alpha: CGFloat = 1) -> CGColor {
    NSColor(
        srgbRed: CGFloat(red) / 255,
        green: CGFloat(green) / 255,
        blue: CGFloat(blue) / 255,
        alpha: alpha
    ).cgColor
}

private func gradient(
    colors: [CGColor],
    locations: [CGFloat],
    colorSpace: CGColorSpace
) -> CGGradient {
    guard let result = CGGradient(
        colorsSpace: colorSpace,
        colors: colors as CFArray,
        locations: locations
    ) else {
        fatalError("Could not create icon gradient")
    }
    return result
}

private func drawIcon(in context: CGContext, colorSpace: CGColorSpace) {
    let fullRect = CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
    context.clear(fullRect)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // Keep a transparent perimeter so the icon has the same visual weight as
    // modern macOS rounded-square icons instead of appearing edge-to-edge.
    let tileRect = CGRect(x: 72, y: 72, width: 880, height: 880)
    let tileRadius: CGFloat = 218
    let tilePath = CGPath(
        roundedRect: tileRect,
        cornerWidth: tileRadius,
        cornerHeight: tileRadius,
        transform: nil
    )

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -25),
        blur: 46,
        color: color(32, 11, 65, alpha: 0.34)
    )
    context.addPath(tilePath)
    context.setFillColor(color(109, 48, 214))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let background = gradient(
        colors: [
            color(91, 48, 218),
            color(159, 53, 218),
            color(238, 72, 169),
            color(255, 111, 149)
        ],
        locations: [0, 0.36, 0.72, 1],
        colorSpace: colorSpace
    )
    context.drawLinearGradient(
        background,
        start: CGPoint(x: tileRect.minX + 65, y: tileRect.maxY - 35),
        end: CGPoint(x: tileRect.maxX - 35, y: tileRect.minY + 45),
        options: []
    )

    // Layered glows give the small icon depth without introducing noisy detail.
    let upperGlow = gradient(
        colors: [color(255, 255, 255, alpha: 0.24), color(255, 255, 255, alpha: 0)],
        locations: [0, 1],
        colorSpace: colorSpace
    )
    context.drawRadialGradient(
        upperGlow,
        startCenter: CGPoint(x: 300, y: 820),
        startRadius: 0,
        endCenter: CGPoint(x: 300, y: 820),
        endRadius: 480,
        options: [.drawsAfterEndLocation]
    )

    let lowerGlow = gradient(
        colors: [color(255, 99, 190, alpha: 0.34), color(255, 99, 190, alpha: 0)],
        locations: [0, 1],
        colorSpace: colorSpace
    )
    context.drawRadialGradient(
        lowerGlow,
        startCenter: CGPoint(x: 790, y: 225),
        startRadius: 0,
        endCenter: CGPoint(x: 790, y: 225),
        endRadius: 520,
        options: [.drawsAfterEndLocation]
    )

    let sheenPath = CGMutablePath()
    sheenPath.move(to: CGPoint(x: tileRect.minX, y: 680))
    sheenPath.addCurve(
        to: CGPoint(x: tileRect.maxX, y: 815),
        control1: CGPoint(x: 330, y: 890),
        control2: CGPoint(x: 690, y: 655)
    )
    sheenPath.addLine(to: CGPoint(x: tileRect.maxX, y: tileRect.maxY))
    sheenPath.addLine(to: CGPoint(x: tileRect.minX, y: tileRect.maxY))
    sheenPath.closeSubpath()
    context.addPath(sheenPath)
    context.setFillColor(color(255, 255, 255, alpha: 0.08))
    context.fillPath()
    context.restoreGState()

    let innerTileRect = tileRect.insetBy(dx: 3, dy: 3)
    let innerTilePath = CGPath(
        roundedRect: innerTileRect,
        cornerWidth: tileRadius - 3,
        cornerHeight: tileRadius - 3,
        transform: nil
    )
    context.addPath(innerTilePath)
    context.setStrokeColor(color(255, 255, 255, alpha: 0.18))
    context.setLineWidth(5)
    context.strokePath()

    // A bold equalizer waveform makes the app read as music at every icon size.
    let barHeights: [CGFloat] = [170, 280, 420, 540, 420, 280, 170]
    let barWidth: CGFloat = 62
    let gap: CGFloat = 28
    let totalWidth = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    let startX = (CGFloat(canvasSize) - totalWidth) / 2

    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -18),
        blur: 30,
        color: color(57, 14, 104, alpha: 0.38)
    )
    for (index, height) in barHeights.enumerated() {
        let rect = CGRect(
            x: startX + CGFloat(index) * (barWidth + gap),
            y: (CGFloat(canvasSize) - height) / 2,
            width: barWidth,
            height: height
        )
        let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        context.addPath(path)
        context.setFillColor(color(255, 250, 255))
        context.fillPath()
    }
    context.restoreGState()

    // A slim highlight on each bar keeps the waveform dimensional and crisp.
    for (index, height) in barHeights.enumerated() {
        let highlight = CGRect(
            x: startX + CGFloat(index) * (barWidth + gap) + 9,
            y: (CGFloat(canvasSize) - height) / 2 + 14,
            width: 12,
            height: max(24, height - 28)
        )
        let path = CGPath(roundedRect: highlight, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(path)
        context.setFillColor(color(255, 255, 255, alpha: 0.28))
        context.fillPath()
    }
}

private func writeIcon(to outputURL: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: canvasSize * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(
            domain: "LikedSongsFocus.IconRenderer",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not create a bitmap context"]
        )
    }

    drawIcon(in: context, colorSpace: colorSpace)

    guard let image = context.makeImage() else {
        throw NSError(
            domain: "LikedSongsFocus.IconRenderer",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Could not create the rendered image"]
        )
    }

    let representation = NSBitmapImageRep(cgImage: image)
    representation.size = NSSize(width: canvasSize, height: canvasSize)
    guard let png = representation.representation(
        using: .png,
        properties: [.compressionFactor: 1]
    ) else {
        throw NSError(
            domain: "LikedSongsFocus.IconRenderer",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not encode the icon as PNG"]
        )
    }

    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
}

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: render_icon.swift <output-1024.png>\n", stderr)
    exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
do {
    try writeIcon(to: outputURL)
    print("Rendered 1024 px icon: \(outputURL.path)")
} catch {
    fputs("Icon rendering failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
