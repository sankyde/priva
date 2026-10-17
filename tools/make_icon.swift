// Renders the Priva app icon (light, dark and tinted variants) at 1024×1024.
// Usage: swift tools/make_icon.swift <output-dir>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The mark: a "P" made of a stem and a closed bowl, with a keyhole inside the bowl.
/// Geometry is on a 1024 canvas; the in-app SwiftUI `PrivaMark` uses the same numbers.
func markPath() -> (stroke: CGPath, keyhole: CGPath) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 392, y: 796))       // bottom of stem (y grows downward in our design space)
    p.addLine(to: CGPoint(x: 392, y: 452))
    p.addArc(center: CGPoint(x: 572, y: 452), radius: 180, startAngle: .pi, endAngle: .pi * 3, clockwise: false)
    let key = CGMutablePath()
    key.addEllipse(in: CGRect(x: 572 - 48, y: 408 - 48, width: 96, height: 96))
    key.move(to: CGPoint(x: 572 - 24, y: 420))
    key.addLine(to: CGPoint(x: 572 + 24, y: 420))
    key.addLine(to: CGPoint(x: 572 + 40, y: 540))
    key.addQuadCurve(to: CGPoint(x: 572 - 40, y: 540), control: CGPoint(x: 572, y: 556))
    key.closeSubpath()
    return (p, key)
}

enum Variant { case light, dark, tinted }

func render(_ v: Variant, to path: String) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip to a top-left origin so the design coordinates read naturally.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    switch v {
    case .light, .dark:
        if v == .light {
            let bg = CGGradient(colorsSpace: cs, colors: [color(0x14163A), color(0x07080D)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])
            // Soft aurora glow behind the bowl.
            let glow = CGGradient(colorsSpace: cs, colors: [color(0x6C5CFF, 0.55), color(0x3EC6FF, 0.0)] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 430), startRadius: 0,
                                   endCenter: CGPoint(x: 512, y: 430), endRadius: 520, options: [])
        }
    case .tinted:
        break
    }

    // Optical centring: the mark's bounding box is centred at (572, 534) in design space.
    ctx.translateBy(x: -60, y: -22)
    let (stroke, keyhole) = markPath()
    ctx.saveGState()
    ctx.addPath(stroke)
    ctx.setLineWidth(132)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    if v == .tinted {
        ctx.setFillColor(color(0xFFFFFF))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    } else {
        let aurora = CGGradient(colorsSpace: cs, colors: [color(0x8B7BFF), color(0x6C5CFF), color(0x3EC6FF)] as CFArray,
                                locations: [0, 0.45, 1])!
        ctx.drawLinearGradient(aurora, start: CGPoint(x: 300, y: 220), end: CGPoint(x: 780, y: 820), options: [])
    }
    ctx.restoreGState()

    // Glass highlight along the top of the bowl.
    if v != .tinted {
        ctx.saveGState()
        let hl = CGMutablePath()
        hl.addArc(center: CGPoint(x: 572, y: 452), radius: 222, startAngle: .pi * 1.12, endAngle: .pi * 1.62, clockwise: false)
        ctx.addPath(hl)
        ctx.setLineWidth(22)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(color(0xFFFFFF, 0.35))
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(keyhole)
    if v == .tinted {
        ctx.setFillColor(color(0xFFFFFF, 0.75))
    } else {
        ctx.setShadow(offset: .zero, blur: 40, color: color(0x3DDC97, 0.9))
        ctx.setFillColor(color(0xEFFFF8))
    }
    ctx.fillPath()
    ctx.restoreGState()

    let img = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(.light, to: "\(out)/AppIcon.png")
render(.dark, to: "\(out)/AppIcon-Dark.png")
render(.tinted, to: "\(out)/AppIcon-Tinted.png")
print("icons written to \(out)")
