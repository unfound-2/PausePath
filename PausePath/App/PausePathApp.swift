import SwiftUI
import AuthenticationServices
import UIKit

@main struct PausePathApp: App {
    var body: some Scene { WindowGroup { LaunchExperienceView() } }
}

private struct LaunchExperienceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finished = false
    @State private var appeared = false
    @State private var trailProgress: CGFloat = 0
    @State private var showsPause = false
    @State private var exiting = false
    @State private var health = HealthActivityStore()
    @State private var account = PausePathAccount.shared
    @AppStorage("pausepath.onboarding.permissions-gate.complete") private var onboardingComplete = false

    private let mint = Color(red: 0.92, green: 0.99, blue: 0.96)
    private let teal = Color(red: 0.01, green: 0.30, blue: 0.35)
    private let lime = Color(red: 0.70, green: 0.92, blue: 0.08)

    var body: some View {
        ZStack {
            if finished || exiting {
                Group {
                    if onboardingComplete {
                        ContentView(health: health)
                    } else {
                        WelcomeSetupView(account: account, health: health) {
                            onboardingComplete = true
                        }
                    }
                }
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
                    .scaleEffect(exiting && !reduceMotion ? 0.55 : 1)
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
                LaunchTrail(progress: trailProgress).fill(lime)
                    .clipShape(LaunchMarker())
                ZStack {
                    HStack(spacing: width * 0.05) {
                        ForEach(0..<2) { _ in
                            RoundedRectangle(cornerRadius: width * 0.045)
                                .frame(width: width * 0.117, height: height * 0.25)
                        }
                    }
                    .opacity(showsPause ? 1 : 0)
                    .scaleEffect(showsPause || reduceMotion ? 1 : 0.65)
                    Image(systemName: "play.fill")
                        .font(.system(size: width * 0.29, weight: .black))
                        .opacity(showsPause ? 0 : 1)
                        .scaleEffect(showsPause && !reduceMotion ? 0.65 : 1)
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
        trailProgress = 0
        showsPause = false
        exiting = false
        do {
            if reduceMotion {
                showsPause = true
                trailProgress = 1
                withAnimation(.easeOut(duration: 0.2)) { appeared = true }
                try await Task.sleep(for: .milliseconds(650))
            } else {
                withAnimation(.easeOut(duration: 0.45)) { appeared = true }
                try await Task.sleep(for: .milliseconds(500))
                withAnimation(.easeInOut(duration: 1.35)) { trailProgress = 1 }
                try await Task.sleep(for: .milliseconds(1450))
                withAnimation(.easeInOut(duration: 0.35)) { showsPause = true }
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

@MainActor
private struct WelcomeSetupView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State var account: PausePathAccount
    let health: HealthActivityStore
    let onContinue: () -> Void
    @State private var locationDiscovery = PlaceDiscovery()
    @State private var healthRequested = false

    private var locationReady: Bool {
        locationDiscovery.authorizationStatus == .authorizedAlways && locationDiscovery.accuracyAuthorization == .fullAccuracy
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image("PausePathLogo").resizable().scaledToFit().frame(height: 88)
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Welcome to PausePath").font(.largeTitle.bold())
                        Text("Connect your account and enable precise location before exploring. You control Health access.")
                            .font(.body).foregroundStyle(.secondary)
                    }

                    setupCard(title: "Sign in with Apple", subtitle: "Required to continue. PausePath uses your account for community features and to keep your settings connected.", icon: "person.crop.circle") {
                        if account.isSignedIn {
                            Label("Signed in with Apple", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            SignInWithAppleButton(.continue) { request in
                                account.prepareAppleSignIn(request)
                            } onCompletion: { result in
                                Task { await account.completeAppleSignIn(result) }
                            }
                            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                            .frame(height: 48)
                            .disabled(account.busy)
                            if account.busy { ProgressView("Signing in…") }
                            Text(account.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    setupCard(title: "Connect Apple Health", subtitle: "PausePath can read walking workouts, walking speed, and recorded heart rate for progress summaries. It never writes to Health. You can choose what to share in Apple’s prompt.", icon: "heart.text.square") {
                        if health.isLoading {
                            ProgressView("Requesting Health access…")
                        } else {
                            Button(healthRequested ? "Review Health access" : "Connect Apple Health", systemImage: "heart") {
                                healthRequested = true
                                Task { await health.connect() }
                            }.buttonStyle(.bordered)
                            Text(health.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    setupCard(title: "Always + Precise location", subtitle: "Required for nearby routes and live GPS while a walk is active. PausePath stops location tracking when you pause or end the walk.", icon: "location") {
                        if locationReady {
                            Label("Always and Precise are enabled", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button(locationNeedsSettings ? "Open Location Settings" : "Enable Always + Precise", systemImage: "location.fill") {
                                if locationNeedsSettings {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                } else {
                                    locationDiscovery.requestAlwaysPreciseLocation()
                                }
                            }.buttonStyle(.bordered)
                            if locationDiscovery.authorizationStatus == .authorizedWhenInUse ||
                                (locationDiscovery.authorizationStatus == .authorizedAlways && locationDiscovery.accuracyAuthorization == .reducedAccuracy) {
                                Button("Open Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                                }.font(.caption.weight(.semibold))
                            }
                            Text(locationDiscovery.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Button(action: onContinue) {
                        Text("Continue to Explore").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }.buttonStyle(.borderedProminent)
                        .disabled(!account.isSignedIn || !locationReady)
                    if !account.isSignedIn {
                        Text("Sign in with Apple to continue.").font(.caption).foregroundStyle(.secondary)
                    } else if !locationReady {
                        Text("Turn on Always and Precise location to continue. If iOS has already asked, open Settings to change it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Health access is optional. Apple controls these permissions; PausePath cannot enable access for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: 0, alignment: .top)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await account.checkAppleCredential() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, locationDiscovery.authorizationStatus == .authorizedAlways,
               locationDiscovery.accuracyAuthorization == .reducedAccuracy {
                locationDiscovery.requestAlwaysPreciseLocation()
            }
        }
    }

    private var locationNeedsSettings: Bool {
        locationDiscovery.authorizationStatus == .denied || locationDiscovery.authorizationStatus == .restricted
    }

    private func setupCard<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            content()
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

// Separate vector layers let the trail draw independently of the marker.
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
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    // Paired edges run from the marker tip to the top of the winding trail.
    // Drawing both edges together preserves the logo's changing ribbon width.
    private let outer: [[CGPoint]] = [
        [.init(x: 0.49, y: 1), .init(x: 0.572, y: 0.933), .init(x: 0.653, y: 0.867), .init(x: 0.735, y: 0.80)],
        [.init(x: 0.735, y: 0.80), .init(x: 0.70, y: 0.67), .init(x: 0.45, y: 0.66), .init(x: 0.41, y: 0.61)],
        [.init(x: 0.41, y: 0.61), .init(x: 0.36, y: 0.55), .init(x: 0.65, y: 0.54), .init(x: 0.74, y: 0.49)],
        [.init(x: 0.74, y: 0.49), .init(x: 0.82, y: 0.44), .init(x: 0.68, y: 0.38), .init(x: 0.37, y: 0.396)]
    ]
    private let inner: [[CGPoint]] = [
        [.init(x: 0.49, y: 1), .init(x: 0.63, y: 0.80), .init(x: 0.40, y: 0.79), .init(x: 0.30, y: 0.73)],
        [.init(x: 0.30, y: 0.73), .init(x: 0.20, y: 0.69), .init(x: 0.17, y: 0.65), .init(x: 0.23, y: 0.61)],
        [.init(x: 0.23, y: 0.61), .init(x: 0.30, y: 0.54), .init(x: 0.52, y: 0.52), .init(x: 0.60, y: 0.48)],
        [.init(x: 0.60, y: 0.48), .init(x: 0.71, y: 0.44), .init(x: 0.51, y: 0.42), .init(x: 0.37, y: 0.396)]
    ]

    func path(in rect: CGRect) -> Path {
        let amount = min(max(progress, 0), 1)
        guard amount > 0 else { return Path() }
        let steps = 160
        let samples = (0...steps).map { amount * CGFloat($0) / CGFloat(steps) }
        var path = Path()
        path.move(to: point(on: outer, at: 0, in: rect))
        for sample in samples.dropFirst() {
            path.addLine(to: point(on: outer, at: sample, in: rect))
        }
        for sample in samples.reversed() {
            path.addLine(to: point(on: inner, at: sample, in: rect))
        }
        path.closeSubpath()
        return path
    }

    private func point(on segments: [[CGPoint]], at progress: CGFloat, in rect: CGRect) -> CGPoint {
        let position = progress * CGFloat(segments.count)
        let index = min(Int(position), segments.count - 1)
        let t = position - CGFloat(index)
        let u = 1 - t
        let points = segments[index]
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        let x = a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x
        let y = a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y
        return CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
}
extension FacilityKind {
    var symbol: String {
        switch self { case .bench: "chair.fill"; case .bathroom: "figure.stand"; case .fountain: "drop.fill"; case .cafe: "cup.and.saucer.fill" }
    }
}
