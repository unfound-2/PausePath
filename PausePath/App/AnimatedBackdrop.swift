import SwiftUI

/// Decorative backdrop for the Community, My Path and Profile tabs.
///
/// A calm "trail map": the brand background with a soft teal wash, two slow
/// aurora glows in lime and teal, and topographic contour rings that echo the
/// Adventure header artwork. Motion is a slow GPU-composited drift (no per-frame
/// redrawing), it is completely still with Reduce Motion, and it never takes
/// touches or VoiceOver focus.
struct PausePathAnimatedBackdrop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let span = max(width, height)
            ZStack {
                PausePathPalette.background
                LinearGradient(colors: [PausePathPalette.teal.opacity(0),
                                        PausePathPalette.teal.opacity(dark ? 0.20 : 0.08)],
                               startPoint: .top, endPoint: .bottom)

                // Aurora glows: lime high on the right, teal low on the left.
                BackdropGlow(color: PausePathPalette.lime, opacity: dark ? 0.16 : 0.30)
                    .frame(width: span * 0.95, height: span * 0.95)
                    .position(x: width * 0.95, y: height * 0.04)
                    .modifier(BackdropDrift(enabled: !reduceMotion, x: 26, y: 18, scale: 1.08, duration: 13))
                BackdropGlow(color: PausePathPalette.teal, opacity: dark ? 0.34 : 0.16)
                    .frame(width: span * 1.05, height: span * 1.05)
                    .position(x: width * 0.02, y: height * 0.70)
                    .modifier(BackdropDrift(enabled: !reduceMotion, x: -22, y: 30, scale: 1.1, duration: 17))
                BackdropGlow(color: PausePathPalette.lime, opacity: dark ? 0.08 : 0.14)
                    .frame(width: span * 0.6, height: span * 0.6)
                    .position(x: width * 0.85, y: height * 1.0)
                    .modifier(BackdropDrift(enabled: !reduceMotion, x: -18, y: -14, scale: 1.12, duration: 21))

                // Topographic contours, like the hill on a trail map.
                ContourRings(center: UnitPoint(x: 1.02, y: 0.86), rings: 10, spacing: 30)
                    .stroke(PausePathPalette.teal.opacity(dark ? 0.16 : 0.09), lineWidth: 1)
                    .modifier(BackdropDrift(enabled: !reduceMotion, x: 0, y: 0, scale: 1.03, rotation: 5,
                                            anchor: UnitPoint(x: 1.02, y: 0.86), duration: 24))
                ContourRings(center: UnitPoint(x: -0.06, y: 0.16), rings: 6, spacing: 28)
                    .stroke(PausePathPalette.teal.opacity(dark ? 0.12 : 0.07), lineWidth: 1)
                    .modifier(BackdropDrift(enabled: !reduceMotion, x: 0, y: 0, scale: 1.03, rotation: -4,
                                            anchor: UnitPoint(x: -0.06, y: 0.16), duration: 29))
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A soft round light that fades to nothing at its edge.
private struct BackdropGlow: View {
    let color: Color
    let opacity: Double
    var body: some View {
        Circle().fill(EllipticalGradient(colors: [color.opacity(opacity), color.opacity(opacity * 0.4), color.opacity(0)],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
    }
}

/// Slow back-and-forth drift, animated by SwiftUI's phase animator so it never
/// leaks into other animations on the screen.
private struct BackdropDrift: ViewModifier {
    let enabled: Bool
    var x: CGFloat = 0
    var y: CGFloat = 0
    var scale: CGFloat = 1
    var rotation: Double = 0
    var anchor: UnitPoint = .center
    let duration: Double

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.phaseAnimator([false, true]) { view, moved in
                view.scaleEffect(moved ? scale : 1, anchor: anchor)
                    .rotationEffect(.degrees(moved ? rotation : 0), anchor: anchor)
                    .offset(x: moved ? x : 0, y: moved ? y : 0)
            } animation: { _ in
                .easeInOut(duration: duration)
            }
        } else {
            content
        }
    }
}

/// Concentric, gently irregular rings around a point (which may sit off-screen).
private struct ContourRings: Shape {
    let center: UnitPoint
    let rings: Int
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = CGPoint(x: rect.minX + rect.width * center.x, y: rect.minY + rect.height * center.y)
        let samples = 120
        for ring in 1...max(1, rings) {
            let base = CGFloat(ring) * spacing + 18
            let seed = Double(ring)
            for index in 0...samples {
                let angle = Double(index) / Double(samples) * 2 * Double.pi
                let wobble = 1 + 0.08 * sin(3 * angle + seed * 0.55) + 0.035 * cos(5 * angle - seed * 0.8)
                let radius = base * CGFloat(wobble)
                let point = CGPoint(x: origin.x + radius * CGFloat(cos(angle)),
                                    y: origin.y + radius * CGFloat(sin(angle)) * 0.78)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        }
        return path
    }
}

extension View {
    /// Same styling as pausePathSurface(), on the animated trail-map backdrop.
    /// The navigation bar keeps the system's automatic behaviour: clear at the
    /// top so the backdrop flows underneath, frosted once content scrolls.
    func pausePathAnimatedSurface() -> some View {
        self.scrollContentBackground(.hidden)
            .background { PausePathAnimatedBackdrop() }
            .tint(PausePathPalette.teal)
            .fontDesign(.rounded)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}
