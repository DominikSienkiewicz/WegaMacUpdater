#!/usr/bin/env swift
// make-icon.swift — renderuje WegaIcon do build/AppIcon.icns
// Użycie: swift scripts/make-icon.swift
import AppKit
import Foundation

// ---------------------------------------------------------------------------
// Rysowanie WegaIcon (odwzorowanie Sources/MacUpdater/WegaViews.swift)
// Układ współrzędnych: 100×100 viewBox, (0,0) lewy górny róg, y w dół
// ---------------------------------------------------------------------------

func makeIcon(size: Int) -> Data? {
    let s = CGFloat(size)

    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // Odwróć oś Y żeby (0,0) było w lewym górnym rogu (jak SwiftUI Canvas)
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    let u = s / 100   // jednostka: 1 punkt viewBox = u pikseli

    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * u, y: y * u) }

    // ---- Tło: gradient jak w WegaIcon ----
    let radius = s * 0.22
    let bgPath = CGPath(
        roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
        cornerWidth: radius, cornerHeight: radius, transform: nil
    )
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gradColors = [
        CGColor(red: 0.94, green: 0.78, blue: 0.54, alpha: 1),
        CGColor(red: 0.72, green: 0.48, blue: 0.23, alpha: 1),
    ] as CFArray
    let locs: [CGFloat] = [0, 1]
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: gradColors, locations: locs) {
        ctx.drawLinearGradient(grad,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: s, y: s),
            options: [])
    }
    ctx.restoreGState()

    let darkEar  = CGColor(red: 0.23, green: 0.16, blue: 0.09, alpha: 1)
    let headTan  = CGColor(red: 0.94, green: 0.85, blue: 0.71, alpha: 1)
    let eyeColor = CGColor(red: 0.12, green: 0.08, blue: 0.04, alpha: 1)
    let noseColor = CGColor(red: 0.05, green: 0.03, blue: 0.02, alpha: 1)

    // ---- Lewe ucho ----
    let leftEar = CGMutablePath()
    leftEar.move(to: pt(22, 46))
    leftEar.addLine(to: pt(30, 4))
    leftEar.addLine(to: pt(42, 42))
    leftEar.closeSubpath()
    ctx.setFillColor(darkEar)
    ctx.addPath(leftEar); ctx.fillPath()

    // ---- Prawe ucho ----
    let rightEar = CGMutablePath()
    rightEar.move(to: pt(58, 42))
    rightEar.addLine(to: pt(70, 4))
    rightEar.addLine(to: pt(78, 46))
    rightEar.closeSubpath()
    ctx.setFillColor(darkEar)
    ctx.addPath(rightEar); ctx.fillPath()

    // ---- Głowa ----
    let head = CGMutablePath()
    head.move(to: pt(26, 44))
    head.addQuadCurve(to: pt(34, 35), control: pt(26, 36))
    head.addLine(to: pt(66, 35))
    head.addQuadCurve(to: pt(74, 44), control: pt(74, 36))
    head.addLine(to: pt(74, 64))
    head.addQuadCurve(to: pt(62, 80), control: pt(74, 76))
    head.addQuadCurve(to: pt(38, 80), control: pt(50, 84))
    head.addQuadCurve(to: pt(26, 64), control: pt(26, 76))
    head.closeSubpath()
    ctx.setFillColor(headTan)
    ctx.addPath(head); ctx.fillPath()

    // ---- Lewe oko ----
    ctx.setFillColor(eyeColor)
    ctx.fillEllipse(in: CGRect(x: 33*u, y: 50*u, width: 8*u, height: 9*u))

    // ---- Prawe oko ----
    ctx.fillEllipse(in: CGRect(x: 59*u, y: 50*u, width: 8*u, height: 9*u))

    // ---- Nos ----
    let nose = CGMutablePath()
    nose.move(to: pt(44, 64))
    nose.addQuadCurve(to: pt(56, 64), control: pt(50, 62))
    nose.addQuadCurve(to: pt(56, 70), control: pt(58, 68))
    nose.addQuadCurve(to: pt(44, 70), control: pt(50, 72))
    nose.addQuadCurve(to: pt(44, 64), control: pt(42, 68))
    nose.closeSubpath()
    ctx.setFillColor(noseColor)
    ctx.addPath(nose); ctx.fillPath()

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
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
