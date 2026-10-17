import AppKit

// Derive the required opaque 1024px icon from the supplied brand artwork.
// Run from the repository root; the original logo remains unchanged.
let source = "PausePath/Resources/Branding/AppIconSource.png"
let destination = "PausePath/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
guard let image = NSImage(contentsOfFile: source),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let context = CGContext(data: nil, width: 1024, height: 1024,
          bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("Could not load PausePath logo")
}
context.interpolationQuality = .high
context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
