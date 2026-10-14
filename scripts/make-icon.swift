import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.25, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 210, yRadius: 210).fill()
        for (x, y, bright) in [(235, 549, true), (549, 549, false), (235, 235, false), (549, 235, true)] {
            (bright ? NSColor(calibratedRed: 0.74, green: 0.91, blue: 0.72, alpha: 1) : NSColor(calibratedRed: 0.40, green: 0.65, blue: 0.52, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 240, height: 240), xRadius: 55, yRadius: 55).fill()
        }
        NSColor(calibratedRed: 0.12, green: 0.32, blue: 0.25, alpha: 1).setStroke()
        let check = NSBezierPath(); check.lineWidth = 24; check.lineCapStyle = .round; check.lineJoinStyle = .round
        check.move(to: NSPoint(x: 603, y: 350)); check.line(to: NSPoint(x: 651, y: 306)); check.line(to: NSPoint(x: 734, y: 400)); check.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
