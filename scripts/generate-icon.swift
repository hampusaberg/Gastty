#!/usr/bin/env swift
//
// Render the same prompt-glyph icon AppDelegate draws at runtime, write
// out a multi-resolution .iconset, and convert it to an .icns via
// iconutil. The .icns gets bundled into the .app so Finder / the Dock
// (before launch) show the proper icon instead of the generic blank.
//
// Usage:   scripts/generate-icon.swift [output-dir]
// Default: writes Resources/AppIcon.icns relative to the repo root.
//
// Re-run this whenever the design in `AppDelegate.makeAppIcon()` changes
// so the on-disk icns stays in sync with the runtime drawing.

import Cocoa
import Foundation

/// Mirror of `AppDelegate.makeAppIcon()`. Kept here as a duplicate (rather
/// than imported) because this is a standalone `swift` script and Cocoa
/// is the only dependency we want to pull in.
func renderIcon() -> NSImage {
    let size = NSSize(width: 1024, height: 1024)
    return NSImage(size: size, flipped: false) { rect in
        let bodyInset: CGFloat = 100
        let body = rect.insetBy(dx: bodyInset, dy: bodyInset)
        let radius: CGFloat = 184

        let bgPath = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.12, alpha: 1).setFill()
        bgPath.fill()

        let innerInset = body.insetBy(dx: 12, dy: 12)
        let strokePath = NSBezierPath(roundedRect: innerInset,
                                      xRadius: radius - 12,
                                      yRadius: radius - 12)
        NSColor(white: 1, alpha: 0.06).setStroke()
        strokePath.lineWidth = 4
        strokePath.stroke()

        let text: NSString = "›_"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: body.height * 0.45, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.65, green: 0.78, blue: 1.0, alpha: 1),
        ]
        let glyphSize = text.size(withAttributes: attrs)
        let glyphRect = NSRect(
            x: body.midX - glyphSize.width / 2,
            y: body.midY - glyphSize.height / 2 - 30,
            width: glyphSize.width,
            height: glyphSize.height
        )
        text.draw(in: glyphRect, withAttributes: attrs)
        return true
    }
}

/// Rasterise `image` at exactly `pixels × pixels` and write it as PNG.
/// Using NSBitmapImageRep + high-quality interpolation gives crisp
/// downsampled output across the iconset's resolution spread.
func writePNG(_ image: NSImage, to url: URL, pixels: Int) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
    ) else {
        throw NSError(domain: "icon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

// macOS expects these exact filenames inside an .iconset — iconutil
// rejects anything else.
let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let outDirArg = CommandLine.arguments.dropFirst().first ?? "Resources"
let outDir = URL(fileURLWithPath: outDirArg, isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let icon = renderIcon()
for (name, pixels) in sizes {
    try writePNG(icon, to: iconset.appendingPathComponent(name), pixels: pixels)
}

let icnsOut = outDir.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icnsOut.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed with status \(proc.terminationStatus)\n".data(using: .utf8)!)
    exit(Int32(proc.terminationStatus))
}

try? FileManager.default.removeItem(at: iconset)
print("Wrote \(icnsOut.path)")
