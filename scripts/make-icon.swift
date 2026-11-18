#!/usr/bin/env swift
// make-icon.swift — skaluje zatwierdzoną grafikę Wegi do build/AppIcon.icns
// Użycie: swift scripts/make-icon.swift
import AppKit
import Foundation

let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/MacUpdater/Resources/WegaAppIcon.png")
guard let source = NSImage(contentsOf: sourceURL),
      let artwork = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("❌ Nie można odczytać zatwierdzonej grafiki WegaAppIcon.png\n", stderr)
    exit(1)
}

func makeIcon(size: Int) -> Data? {
    guard let context = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

// ---------------------------------------------------------------------------
// Generowanie iconset i konwersja do .icns
// ---------------------------------------------------------------------------

let buildDir = "build"
let iconsetDir = "\(buildDir)/WegaMacUpdater.iconset"
let icnsPath = "\(buildDir)/AppIcon.icns"

try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let specs: [(filename: String, px: Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

print("→ Generuję PNG...")
for spec in specs {
    guard let data = makeIcon(size: spec.px) else {
        fputs("❌ Błąd przy \(spec.filename)\n", stderr); exit(1)
    }
    let path = "\(iconsetDir)/\(spec.filename)"
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("   ✓ \(spec.filename) (\(spec.px)px)")
    } catch {
        fputs("❌ Zapis \(path): \(error)\n", stderr); exit(1)
    }
}

print("→ iconutil → .icns...")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["--convert", "icns", "--output", icnsPath, iconsetDir]
try! proc.run()
proc.waitUntilExit()

guard proc.terminationStatus == 0 else {
    fputs("❌ iconutil zakończył z błędem\n", stderr); exit(1)
}

print("✅ \(icnsPath)")
