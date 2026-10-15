// Generates app/Resources/AppIcon.icns (run: swift scripts/make-icon.swift).
import AppKit
func c(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = s / 1024
    let rect = NSRect(x: 100*u, y: 100*u, width: 824*u, height: 824*u)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185*u, yRadius: 185*u)
    // drop shadow + light base
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = .black.withAlphaComponent(0.28); sh.shadowBlurRadius = 20*u; sh.shadowOffset = NSSize(width: 0, height: -10*u); sh.set()
    NSGradient(colors: [c(246,248,255), c(214,224,250)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    // split: gentle diagonal, left pane deep blue
    let split = NSBezierPath()
    split.move(to: NSPoint(x: 0, y: 0)); split.line(to: NSPoint(x: 470*u, y: 0))
    split.curve(to: NSPoint(x: 554*u, y: 1024*u), controlPoint1: NSPoint(x: 500*u, y: 420*u), controlPoint2: NSPoint(x: 524*u, y: 600*u))
    split.line(to: NSPoint(x: 0, y: 1024*u)); split.close()
    NSGraphicsContext.current?.saveGraphicsState()
    shape.addClip(); split.addClip()
    NSGradient(colors: [c(78,150,255), c(32,86,232)])!.draw(in: shape, angle: -70)
    NSGraphicsContext.current?.restoreGraphicsState()
    // folder: tab + body
    let fb = NSRect(x: 232*u, y: 300*u, width: 560*u, height: 380*u)
    let folder = NSBezierPath(roundedRect: fb, xRadius: 56*u, yRadius: 56*u)
    let tab = NSBezierPath(roundedRect: NSRect(x: 232*u, y: 620*u, width: 230*u, height: 110*u), xRadius: 40*u, yRadius: 40*u)
    folder.append(tab)
    NSGraphicsContext.current?.saveGraphicsState()
    let fs = NSShadow(); fs.shadowColor = c(20,50,140,0.30); fs.shadowBlurRadius = 36*u; fs.shadowOffset = NSSize(width: 0, height: -18*u); fs.set()
    c(255,255,255).setFill(); folder.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // left half of folder tinted light blue (inverse pane)
    NSGraphicsContext.current?.saveGraphicsState()
    folder.addClip(); split.addClip()
    NSGradient(colors: [c(190,225,255), c(110,170,255)])!.draw(in: fb.union(tab.bounds), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    // right half: soft white→ice
    NSGraphicsContext.current?.saveGraphicsState()
    folder.addClip(); let inv = NSBezierPath(rect: NSRect(x: 0, y: 0, width: s, height: s)); inv.append(split); inv.windingRule = .evenOdd; inv.addClip()
    NSGradient(colors: [c(255,255,255), c(232,238,255)])!.draw(in: fb.union(tab.bounds), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    // folder front-lip highlight line
    c(255,255,255,0.55).setStroke(); let lip = NSBezierPath(); lip.move(to: NSPoint(x: 260*u, y: 618*u)); lip.line(to: NSPoint(x: 764*u, y: 618*u)); lip.lineWidth = 6*u; lip.lineCapStyle = .round; lip.stroke()
    // top gloss
    NSGraphicsContext.current?.saveGraphicsState(); shape.addClip()
    NSGradient(colors: [c(255,255,255,0.22), c(255,255,255,0)])!.draw(in: NSRect(x: 100*u, y: 640*u, width: 824*u, height: 284*u), angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let set = URL(fileURLWithPath: "app/Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print("ok")
