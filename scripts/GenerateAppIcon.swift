import AppKit
// Opaque, scalable PausePath mark: a winding path with a pause/rest point.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(calibratedRed: 0.035, green: 0.24, blue: 0.23, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let path = NSBezierPath()
path.move(to: NSPoint(x: 280, y: -70))
path.curve(to: NSPoint(x: 700, y: 470), controlPoint1: NSPoint(x: 100, y: 310), controlPoint2: NSPoint(x: 840, y: 190))
path.curve(to: NSPoint(x: 490, y: 1090), controlPoint1: NSPoint(x: 550, y: 700), controlPoint2: NSPoint(x: 270, y: 760))
path.lineWidth = 105
path.lineCapStyle = .round
NSColor(calibratedRed: 0.78, green: 0.94, blue: 0.79, alpha: 1).setStroke()
path.stroke()
NSColor(calibratedRed: 0.98, green: 0.76, blue: 0.34, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 310, y: 330, width: 400, height: 400)).fill()
NSColor(calibratedRed: 0.035, green: 0.24, blue: 0.23, alpha: 1).setFill()
for x in [425, 545] { NSBezierPath(roundedRect: NSRect(x: x, y: 425, width: 65, height: 210), xRadius: 18, yRadius: 18).fill() }
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "PausePath/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))
