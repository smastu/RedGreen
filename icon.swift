// アイコン生成：swift icon.swift icon_1024.png
import AppKit
let img = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    let r = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(white: 0.95, alpha: 1).setFill(); shape.fill()
    ctx.restoreGState()
    shape.addClip()
    NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.86, alpha: 1)])!.draw(in: r, angle: -90)
    // 窓のタイトルバー
    NSColor(white: 0.78, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - 300, width: r.width, height: 6)).fill()
    // 赤と緑の丸
    let d: CGFloat = 250, y = r.maxY - 300 + (300 - d) / 2 - 140
    for (x, c) in [(r.midX - d - 40, NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1)),
                   (r.midX + 40, NSColor(red: 0.16, green: 0.79, blue: 0.29, alpha: 1))] {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.25).cgColor)
        c.setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
        ctx.restoreGState()
    }
    // 緑の丸の中に「広げる」矢印、赤の丸に ×
    NSColor.white.setStroke()
    let gx = r.midX + 40 + d / 2, gy = y + d / 2, a: CGFloat = 70
    let arrows = NSBezierPath()
    arrows.move(to: NSPoint(x: gx - a, y: gy - a)); arrows.line(to: NSPoint(x: gx + a, y: gy + a))
    arrows.move(to: NSPoint(x: gx + a - 55, y: gy + a)); arrows.line(to: NSPoint(x: gx + a, y: gy + a)); arrows.line(to: NSPoint(x: gx + a, y: gy + a - 55))
    arrows.move(to: NSPoint(x: gx - a + 55, y: gy - a)); arrows.line(to: NSPoint(x: gx - a, y: gy - a)); arrows.line(to: NSPoint(x: gx - a, y: gy - a + 55))
    arrows.lineWidth = 26; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round; arrows.stroke()
    let rx = r.midX - 40 - d / 2, b: CGFloat = 55
    let x = NSBezierPath()
    x.move(to: NSPoint(x: rx - b, y: gy - b)); x.line(to: NSPoint(x: rx + b, y: gy + b))
    x.move(to: NSPoint(x: rx - b, y: gy + b)); x.line(to: NSPoint(x: rx + b, y: gy - b))
    x.lineWidth = 26; x.lineCapStyle = .round; x.stroke()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)); NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
