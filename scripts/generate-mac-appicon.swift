#!/usr/bin/env swift
// Generates macOS app-icon PNGs from a square 1024x1024 source image.
//
// macOS does not mask icons at render time the way iOS does, so the rounded
// rectangle must be baked into the artwork. This applies Apple's Big Sur icon
// grid: an 824x824 rounded-rect body (corner radius 185.4 @1024) centered on a
// transparent 1024 canvas, with the standard subtle drop shadow.
//
// Usage: swift scripts/generate-mac-appicon.swift <source-1024.png> <output-dir> <file-prefix>
//   e.g. swift scripts/generate-mac-appicon.swift icon_1024x1024.png bitchat/Assets.xcassets/AppIcon.appiconset icon

import AppKit
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: generate-mac-appicon.swift <source.png> <outdir> <prefix>\n".utf8))
    exit(1)
}

let sourcePath = CommandLine.arguments[1]
let outDir = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let prefix = CommandLine.arguments[3]

guard let dataProvider = CGDataProvider(url: URL(fileURLWithPath: sourcePath) as CFURL),
      let source = CGImage(pngDataProviderSource: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
    FileHandle.standardError.write(Data("error: could not read PNG at \(sourcePath)\n".utf8))
    exit(1)
}

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func render(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let side = CGFloat(pixels)
    let inset = side * 100.0 / 1024.0
    let body = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let radius = side * 185.4 / 1024.0
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -side * 10.0 / 1024.0),
        blur: side * 20.0 / 1024.0,
        color: CGColor(colorSpace: sRGB, components: [0, 0, 0, 0.3])
    )
    ctx.addPath(path)
    ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(source, in: body)
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("error: failed to write \(url.path)\n".utf8))
        exit(1)
    }
}

// (point size, scale) for every mac slot in an appiconset
let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in slots {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let url = outDir.appendingPathComponent("\(prefix)_\(points)x\(points)\(suffix).png")
    writePNG(render(pixels: points * scale), to: url)
    print("wrote \(url.lastPathComponent)")
}
