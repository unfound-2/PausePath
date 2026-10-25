// Rebuild the bundled, illustrative onboarding clip on macOS:
// swift -module-cache-path /tmp/pausepath-swift-cache scripts/generate_onboarding_walkthrough.swift
import AppKit
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO

let width = 720
let height = 800
let framesPerSecond: Int32 = 15
let framesPerScene = 51
let frameCount = framesPerScene * 3
let destination = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "PausePath/Resources/PausePathWalkthrough.mp4")

func color(_ rgb: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [
        CGFloat((rgb >> 16) & 255) / 255,
        CGFloat((rgb >> 8) & 255) / 255,
        CGFloat(rgb & 255) / 255,
        alpha
    ])!
}
let mint = color(0xEBFDF6)
let teal = color(0x024B5B)
let lime = color(0xB0E92A)
let muted = color(0x567C7B)
let white = color(0xFFFFFF)
let bench = color(0x146E57)
let bathroom = color(0x6149B0)
let water = color(0x146EBF)
let cafe = color(0xA65221)

func rounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill)
    ctx.fillPath()
}

func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ stroke: CGColor, _ thickness: CGFloat) {
    ctx.setStrokeColor(stroke)
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.round)
    ctx.move(to: a)
    ctx.addLine(to: b)
    ctx.strokePath()
}

func circle(_ ctx: CGContext, _ center: CGPoint, _ radius: CGFloat, _ fill: CGColor) {
    ctx.setFillColor(fill)
    ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

@discardableResult
func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
           _ weight: NSFont.Weight = .regular, _ ink: CGColor = teal,
           width availableWidth: CGFloat = 660) -> CGSize {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor(cgColor: ink)!,
        .paragraphStyle: paragraph
    ]
    let rect = CGRect(x: x, y: y, width: availableWidth, height: 130)
    (text as NSString).draw(in: rect, withAttributes: attributes)
    return (text as NSString).size(withAttributes: attributes)
}

func caption(_ ctx: CGContext, _ title: String, _ subtitle: String, _ number: String) {
    label("PausePath", 46, 31, 27, .bold)
    rounded(ctx, CGRect(x: 471, y: 29, width: 201, height: 34), 17, white)
    label("SAMPLE WALKTHROUGH", 488, 38, 14, .bold)
    label(number, 47, 103, 15, .bold, muted)
    label(title, 46, 135, 41, .heavy)
    label(subtitle, 47, 190, 20, .regular, muted)
    label("Illustration · no live location or facility data", 47, 758, 16, .medium, muted)
}

func settingRow(_ ctx: CGContext, _ y: CGFloat, _ title: String, _ detail: String, _ icon: String) {
    rounded(ctx, CGRect(x: 46, y: y, width: 628, height: 88), 20, white)
    rounded(ctx, CGRect(x: 64, y: y + 18, width: 51, height: 51), 13, color(0xDDF5EA))
    if icon == "bench" {
        rounded(ctx, CGRect(x: 77, y: y + 26, width: 26, height: 17), 3, teal)
        rounded(ctx, CGRect(x: 74, y: y + 47, width: 32, height: 6), 2, teal)
        line(ctx, CGPoint(x: 80, y: y + 52), CGPoint(x: 80, y: y + 60), teal, 3)
        line(ctx, CGPoint(x: 100, y: y + 52), CGPoint(x: 100, y: y + 60), teal, 3)
    } else {
        label(icon, 78, y + 26, 24, .bold)
    }
    label(title, 134, y + 16, 17, .medium, muted)
    label(detail, 134, y + 40, 23, .bold)
}

func sceneSettings(_ ctx: CGContext, _ fraction: CGFloat) {
    caption(ctx, "Plan a walk", "Set distance, terrain, and places to pause.", "1 / 3  ·  SET UP")
    rounded(ctx, CGRect(x: 46, y: 239, width: 628, height: 141), 22, white)
    label("DISTANCE", 68, 259, 17, .bold, muted)
    label(fraction < 0.45 ? "0.8 km" : "1.2 km", 68, 292, 36, .heavy)
    rounded(ctx, CGRect(x: 68, y: 352, width: 580, height: 8), 4, color(0xDFEFE8))
    let sliderX: CGFloat = 68 + 580 * (fraction < 0.45 ? 0.28 : 0.44)
    rounded(ctx, CGRect(x: 68, y: 352, width: sliderX - 68, height: 8), 4, lime)
    circle(ctx, CGPoint(x: sliderX, y: 356), 15, teal)
    settingRow(ctx, 397, "TERRAIN", "Gentle slopes", "↗")
    settingRow(ctx, 500, "REST GAP", "Bench every 400 m", "bench")
    label("STOPS TO INCLUDE", 49, 616, 17, .bold, muted)
    let chipY: CGFloat = 647
    for (x, title, chipColor, chipWidth) in [(46.0, "Bench", bench, 143.0), (198, "Bathroom", bathroom, 177.0), (384, "Water", water, 135.0), (528, "Café", cafe, 146.0)] {
        rounded(ctx, CGRect(x: x, y: chipY, width: chipWidth, height: 50), 25, chipColor)
        label(title, x + 17, chipY + 11, 17, .semibold, white, width: chipWidth - 25)
    }
    rounded(ctx, CGRect(x: 46, y: 710, width: 628, height: 44), 16, lime)
    label("Find routes  →", 293, 719, 19, .bold)
}

func mapSurface(_ ctx: CGContext) {
    rounded(ctx, CGRect(x: 46, y: 237, width: 628, height: 377), 25, color(0xDBEFE4))
    ctx.saveGState()
    ctx.clip(to: CGRect(x: 46, y: 237, width: 628, height: 377))
    for x in stride(from: CGFloat(46), through: CGFloat(674), by: 56) {
        line(ctx, CGPoint(x: x, y: 237), CGPoint(x: x, y: 614), color(0xBDDCCF), 1)
    }
    for y in stride(from: CGFloat(237), through: CGFloat(614), by: 56) {
        line(ctx, CGPoint(x: 46, y: y), CGPoint(x: 674, y: y), color(0xBDDCCF), 1)
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 95, y: 535))
    path.addCurve(to: CGPoint(x: 337, y: 416), control1: CGPoint(x: 259, y: 578), control2: CGPoint(x: 190, y: 386))
    path.addCurve(to: CGPoint(x: 621, y: 308), control1: CGPoint(x: 520, y: 459), control2: CGPoint(x: 475, y: 280))
    ctx.addPath(path); ctx.setStrokeColor(white); ctx.setLineWidth(18); ctx.setLineCap(.round); ctx.strokePath()
    ctx.addPath(path); ctx.setStrokeColor(teal); ctx.setLineWidth(9); ctx.setLineCap(.round); ctx.strokePath()
    circle(ctx, CGPoint(x: 95, y: 535), 16, lime)
    circle(ctx, CGPoint(x: 95, y: 535), 6, teal)
    for (point, fill, title) in [
        (CGPoint(x: 204, y: 493), bench, "B"),
        (CGPoint(x: 338, y: 416), bathroom, "WC"),
        (CGPoint(x: 480, y: 370), water, "W"),
        (CGPoint(x: 595, y: 306), cafe, "C")
    ] {
        circle(ctx, point, 27, white)
        circle(ctx, point, 22, fill)
        label(title, point.x - (title == "WC" ? 15 : 9), point.y - 15, title == "WC" ? 16 : 22, .bold, white, width: 48)
    }
    ctx.restoreGState()
}

func sceneRoute(_ ctx: CGContext, _ fraction: CGFloat) {
    caption(ctx, "Review the route", "Compare distance, slope, and planned pauses.", "2 / 3  ·  PREVIEW")
    mapSurface(ctx)
    rounded(ctx, CGRect(x: 68, y: 584, width: 584, height: 156), 23, white)
    label("Riverside loop", 92, 602, 26, .bold)
    label("1.2 km   ·   18 min", 92, 639, 21, .semibold, muted)
    label("Gentle terrain   ·   3 planned pauses", 92, 674, 19, .medium)
    label("Longest bench gap: about 350 m", 92, 704, 17, .medium, muted)
    if fraction > 0.55 {
        rounded(ctx, CGRect(x: 481, y: 602, width: 139, height: 32), 16, lime)
        label("SAMPLE", 506, 609, 15, .bold)
    }
}

func sceneNavigate(_ ctx: CGContext, _ fraction: CGFloat) {
    caption(ctx, "The next pause", "Keep the next planned stop in view.", "3 / 3  ·  NAVIGATE")
    mapSurface(ctx)
    rounded(ctx, CGRect(x: 68, y: 563, width: 584, height: 177), 23, white)
    rounded(ctx, CGRect(x: 90, y: 582, width: 129, height: 31), 15, color(0xDDF5EA))
    label("NEXT PAUSE", 103, 588, 14, .bold)
    label("Bench", 90, 624, 29, .bold)
    let meters = max(90, 240 - Int(fraction * 150))
    label("\(meters) m ahead", 90, 660, 22, .semibold, teal)
    label("Backrest: unknown   ·   Last check: unknown", 90, 699, 17, .medium, muted)
    circle(ctx, CGPoint(x: 205 + fraction * 105, y: 493 - fraction * 65), 13, lime)
    circle(ctx, CGPoint(x: 205 + fraction * 105, y: 493 - fraction * 65), 5, teal)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: destination)
let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_600_000]
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferIOSurfacePropertiesKey as String: [:]
])
writer.add(input)
guard writer.startWriting() else { throw writer.error ?? NSError(domain: "PausePathVideo", code: 1) }
writer.startSession(atSourceTime: .zero)

for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
    var rawBuffer: CVPixelBuffer?
    guard let pool = adaptor.pixelBufferPool,
          CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rawBuffer) == kCVReturnSuccess,
          let pixelBuffer = rawBuffer else { fatalError("Could not allocate a video frame") }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
        fatalError("Could not create a frame context")
    }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    ctx.setFillColor(mint)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scene = frame / framesPerScene
    let progress = CGFloat(frame % framesPerScene) / CGFloat(framesPerScene - 1)
    switch scene {
    case 0: sceneSettings(ctx, progress)
    case 1: sceneRoute(ctx, progress)
    default: sceneNavigate(ctx, progress)
    }
    if [15, framesPerScene + 15, framesPerScene * 2 + 15].contains(frame),
       let image = ctx.makeImage() {
        let preview = URL(fileURLWithPath: "/tmp/pausepath-walkthrough-\(scene + 1).png")
        if let png = CGImageDestinationCreateWithURL(preview as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(png, image, nil)
            CGImageDestinationFinalize(png)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    let time = CMTime(value: Int64(frame), timescale: framesPerSecond)
    guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
        throw writer.error ?? NSError(domain: "PausePathVideo", code: 2)
    }
}
input.markAsFinished()
let completed = DispatchSemaphore(value: 0)
writer.finishWriting { completed.signal() }
completed.wait()
guard writer.status == .completed else { throw writer.error ?? NSError(domain: "PausePathVideo", code: 3) }
print("Created \(destination.path) (\(frameCount / Int(framesPerSecond)) seconds)")
