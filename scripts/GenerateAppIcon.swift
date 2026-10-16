import AppKit

// Normalize supplied artwork for the iOS app icon. With no argument, use the
// current icon so regeneration never replaces the approved artwork.
let output = URL(fileURLWithPath: "PausePath/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let source = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? output
let image = NSImage(contentsOf: source)!
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor.white.setFill()
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
bounds.fill()
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: bounds)
NSGraphicsContext.restoreGraphicsState()
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
