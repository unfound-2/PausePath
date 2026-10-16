import SwiftUI

@main struct PausePathApp: App {
    var body: some Scene { WindowGroup { LaunchExperienceView() } }
}

private struct LaunchExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var appeared = false
    @State private var pathArrived = false
    @State private var playing = false
    @State private var exiting = false

    private let mint = Color(red: 0.92, green: 0.99, blue: 0.96)
    private let teal = Color(red: 0.01, green: 0.30, blue: 0.35)
    private let lime = Color(red: 0.70, green: 0.92, blue: 0.08)

    var body: some View {
        ZStack {
            if finished || exiting {
                ContentView()
                    .transition(.opacity)
            }
            if !finished {
                mint.ignoresSafeArea()
                    .opacity(exiting ? 0 : 1)
                GeometryReader { geometry in
                    let width = min(geometry.size.width * 0.66, geometry.size.height * 0.43, 290)
                    VStack(spacing: 20) {
                        marker
                            .frame(width: width, height: width * 1.24)
                        (Text("Pause").foregroundColor(teal) + Text("Path").foregroundColor(lime))
                            .font(.system(size: width * 0.22, weight: .black, design: .rounded))
                            .tracking(-width * 0.009)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                    .scaleEffect(exiting && !reduceMotion ? 0.72 : 1)
                    .opacity(appeared && !exiting ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("PausePath")
            }
        }
        .task { await runIntro() }
    }

    private var marker: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .top) {
                LaunchMarker().fill(teal)
                LaunchTrail().fill(lime)
                    .offset(y: pathArrived ? 0 : height)
                    .opacity(pathArrived ? 1 : 0)
                    .clipShape(LaunchMarker())
                ZStack {
                    HStack(spacing: width * 0.05) {
                        ForEach(0..<2) { _ in
                            RoundedRectangle(cornerRadius: width * 0.045)
                                .frame(width: width * 0.117, height: height * 0.25)
                        }
                    }
                    .opacity(playing ? 0 : 1)
                    .scaleEffect(playing && !reduceMotion ? 0.65 : 1)
                    Image(systemName: "play.fill")
                        .font(.system(size: width * 0.29, weight: .black))
                        .opacity(playing ? 1 : 0)
                        .scaleEffect(playing || reduceMotion ? 1 : 0.65)
                }
                .foregroundStyle(lime)
                .frame(width: width, height: height * 0.25)
                .offset(y: height * 0.117)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
        }
    }

    @MainActor
    private func runIntro() async {
        guard !finished else { return }
        // Reset if SwiftUI cancels and restarts this view's task.
        appeared = false
        pathArrived = false
        playing = false
        exiting = false
        do {
            if reduceMotion {
                pathArrived = true
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
                try await Task.sleep(for: .milliseconds(650))
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
                try await Task.sleep(for: .milliseconds(500))
                withAnimation(.spring(response: 0.85, dampingFraction: 0.85)) { pathArrived = true }
                try await Task.sleep(for: .milliseconds(1000))
                withAnimation(.easeInOut(duration: 0.35)) { playing = true }
                try await Task.sleep(for: .milliseconds(650))
            }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.6)) { exiting = true }
            try await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 600))
            finished = true
        } catch {
            // A cancelled launch must never leave an opaque overlay stuck onscreen.
            finished = true
        }
    }
}

// Separate vector layers let the trail move independently of the marker.
// Coordinates follow the supplied logo and scale to every device size.
private struct LaunchMarker: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.5, y: 0))
        path.addCurve(to: CGPoint(x: 1, y: 0.39), control1: CGPoint(x: 0.78, y: 0), control2: CGPoint(x: 1, y: 0.175))
        path.addCurve(to: CGPoint(x: 0.78, y: 0.79), control1: CGPoint(x: 1, y: 0.57), control2: CGPoint(x: 0.91, y: 0.66))
        path.addLine(to: CGPoint(x: 0.51, y: 0.985))
        path.addQuadCurve(to: CGPoint(x: 0.455, y: 0.985), control: CGPoint(x: 0.48, y: 1.02))
        path.addCurve(to: CGPoint(x: 0.08, y: 0.60), control1: CGPoint(x: 0.32, y: 0.86), control2: CGPoint(x: 0.14, y: 0.70))
        path.addCurve(to: CGPoint(x: 0, y: 0.39), control1: CGPoint(x: 0.025, y: 0.52), control2: CGPoint(x: 0, y: 0.46))
        path.addCurve(to: CGPoint(x: 0.5, y: 0), control1: CGPoint(x: 0, y: 0.175), control2: CGPoint(x: 0.22, y: 0))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

private struct LaunchTrail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.37, y: 0.396))
        path.addCurve(to: CGPoint(x: 0.74, y: 0.49), control1: CGPoint(x: 0.68, y: 0.38), control2: CGPoint(x: 0.82, y: 0.44))
        path.addCurve(to: CGPoint(x: 0.41, y: 0.61), control1: CGPoint(x: 0.65, y: 0.54), control2: CGPoint(x: 0.36, y: 0.55))
        path.addCurve(to: CGPoint(x: 0.735, y: 0.80), control1: CGPoint(x: 0.45, y: 0.66), control2: CGPoint(x: 0.70, y: 0.67))
        path.addLine(to: CGPoint(x: 0.49, y: 1))
        path.addCurve(to: CGPoint(x: 0.30, y: 0.73), control1: CGPoint(x: 0.63, y: 0.80), control2: CGPoint(x: 0.40, y: 0.79))
        path.addCurve(to: CGPoint(x: 0.23, y: 0.61), control1: CGPoint(x: 0.20, y: 0.69), control2: CGPoint(x: 0.17, y: 0.65))
        path.addCurve(to: CGPoint(x: 0.60, y: 0.48), control1: CGPoint(x: 0.30, y: 0.54), control2: CGPoint(x: 0.52, y: 0.52))
        path.addCurve(to: CGPoint(x: 0.37, y: 0.396), control1: CGPoint(x: 0.71, y: 0.44), control2: CGPoint(x: 0.51, y: 0.42))
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

extension FacilityKind {
    var symbol: String {
        switch self { case .bench: "chair.fill"; case .bathroom: "figure.stand"; case .fountain: "drop.fill"; case .cafe: "cup.and.saucer.fill" }
    }
}
