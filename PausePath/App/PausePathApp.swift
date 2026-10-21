import SwiftUI
import AuthenticationServices
import UIKit
import UserNotifications

extension Notification.Name {
    static let pausePathShowProgress = Notification.Name("pausepath.showProgress")
    static let pausePathWalkRecorded = Notification.Name("pausepath.walkRecorded")
    static let pausePathJoinCommunity = Notification.Name("pausepath.joinCommunity")
}

final class PausePathNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.identifier == "pausepath.daily-recap" {
            NotificationCenter.default.post(name: .pausePathShowProgress, object: nil)
        }
        completionHandler()
    }
}

/// Adaptive brand colors; ink stays dark for readable text on lime controls.
enum PausePathPalette {
    static let background = Color("BrandBackground")
    static let teal = Color("BrandTeal")
    static let lime = Color("BrandLime")
    static let ink = Color("BrandInk")
    static let surface = Color(.secondarySystemGroupedBackground)
    static let corner: CGFloat = 22
}

extension View {
    func pausePathSurface() -> some View {
        self.scrollContentBackground(.hidden)
            .background(PausePathPalette.background)
            .toolbarBackground(PausePathPalette.background, for: .navigationBar)
            .tint(PausePathPalette.teal)
            .fontDesign(.rounded)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

@main struct PausePathApp: App {
    @UIApplicationDelegateAdaptor(PausePathNotificationDelegate.self) private var notificationDelegate
    var body: some Scene { WindowGroup { LaunchExperienceView().tint(PausePathPalette.teal) } }
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
    @AppStorage("pausepath.onboarding.permissions-gate.v2.complete") private var onboardingComplete = false
    @AppStorage("pausepath.onboarding.personal-goals.v2.complete") private var personalizationComplete = false
    @AppStorage("pausepath.personalProfile") private var profileData = Data()

    private let mint = PausePathPalette.background
    private let teal = PausePathPalette.ink
    private let lime = PausePathPalette.lime

    var body: some View {
        ZStack {
            if finished || exiting {
                Group {
                    if onboardingComplete && personalizationComplete {
                        ContentView(health: health)
                    } else {
                        WelcomeSetupView(account: account, health: health, profileData: $profileData) {
                            onboardingComplete = true
                            personalizationComplete = true
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
                        (Text("Pause").foregroundColor(PausePathPalette.teal) + Text("Path").foregroundColor(lime))
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
        .onOpenURL { url in
            if url.scheme == "pausepath", url.host == "walk" || url.host == "explore" {
                NotificationCenter.default.post(name: .pausePathOpenExplore, object: nil)
                return
            }
            guard url.scheme == "pausepath", url.host == "community", url.path == "/join",
                  let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value,
                  !code.isEmpty else { return }
            UserDefaults.standard.set(code, forKey: "pausepath.pendingCommunityInvite")
            NotificationCenter.default.post(name: .pausePathJoinCommunity, object: nil, userInfo: ["code": code])
        }
        .task { await WalkLiveActivity.endOrphanedActivities(); await runIntro() }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @State var account: PausePathAccount
    let health: HealthActivityStore
    @Binding var profileData: Data
    let onContinue: () -> Void
    @State private var locationDiscovery = PlaceDiscovery()
    @State private var healthRequested = false
    @State private var profile = PausePathProfile()
    @State private var step = 0
    @State private var notificationStatus = "Daily recap notifications are optional. Your recap will also be available in My Path."
    @State private var notificationEnabled = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image("PausePathLogo").resizable().scaledToFit().frame(height: 88)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        ForEach(0..<5, id: \.self) { index in
                            stepDot(index)
                            if index < 4 { Capsule().fill(step > index ? Color.accentColor : Color.secondary.opacity(0.2)).frame(height: 3) }
                        }
                    }
                    page.transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                }.padding(20).frame(maxWidth: 560)
                    .frame(maxWidth: .infinity, minHeight: 0, alignment: .top)
            }
            .background(PausePathPalette.background)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            await account.restoreSessionIfNeeded()
        }
        .onAppear {
            if let saved = try? JSONDecoder().decode(PausePathProfile.self, from: profileData) { profile = saved }
            notificationEnabled = profile.dailyRecapNotifications
            if notificationEnabled { notificationStatus = "Reminder set for 8 PM. You can turn it off at any time." }
        }
        .onChange(of: account.appleProvidedName) { _, name in
            guard let name, profile.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
            profile.username = name
            saveProfile()
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: introductionStep
        case 1: goalStep
        case 2: weeklyGoalStep
        case 3: usernameStep
        default: connectionStep
        }
    }

    private var introductionStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("A little more room for what matters.").font(.largeTitle.bold())
            Text("PausePath helps you find walking routes, notice your progress, and make space for a pause in a way that fits your day.")
                .font(.body).foregroundStyle(.secondary)
            Label("Choose a goal that feels relevant", systemImage: "scope")
            Label("Find routes with details that matter to you", systemImage: "map")
            Label("Reflect on activity without pressure", systemImage: "chart.bar")
            Text("You choose your goal. Sign-in, location, Health, and notifications are optional; PausePath asks for location when you use a location-based feature.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Get started") { advance(to: 1) }
                .buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink).frame(maxWidth: .infinity)
        }
    }

    private var goalStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(.white.opacity(0.62)).frame(width: 68, height: 68)
                    Image(systemName: "figure.walk")
                        .font(.system(size: 31, weight: .medium))
                        .foregroundStyle(PausePathPalette.teal)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your pace. Your plan.").font(.headline)
                    Text("Small steps, chosen by you.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "sparkles").font(.title3).foregroundStyle(PausePathPalette.teal)
            }
            .padding(14)
            .background(LinearGradient(colors: [PausePathPalette.teal.opacity(0.12), PausePathPalette.lime.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 6) {
                Text("What brings you to PausePath?").font(.largeTitle.bold())
                Text("Choose what matters to you. We’ll use it to shape route suggestions and your progress recap. You can change it any time. Your profile stays on this device, and Health data never chooses it for you.")
                    .font(.body).foregroundStyle(.secondary)
            }
            ForEach(PersonalGoalProfile.allCases, id: \.self) { goal in
                Button { withAnimation(reduceMotion ? .linear(duration: 0) : .snappy) { profile.goal = goal; saveProfile() } } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: profile.goal == goal ? "largecircle.fill.circle" : "circle")
                            .font(.title3).foregroundStyle(profile.goal == goal ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(goal.rawValue).font(.headline).foregroundStyle(.primary)
                            if profile.goal == goal {
                                Text(goal.explanation).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16))
                }.buttonStyle(.plain).accessibilityAddTraits(profile.goal == goal ? [.isSelected] : [])
            }
            Text("Goals are yours to adjust. PausePath doesn’t assess symptoms, recovery readiness, or safe exertion. Follow advice from your healthcare professional.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button("Back") { advance(to: 0) }.buttonStyle(.bordered)
                Button {
                    saveProfile()
                    advance(to: 2)
                } label: {
                    Text("Set a weekly goal").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            }
        }
    }

    private var weeklyGoalStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose a goal for your week").font(.largeTitle.bold())
            Text("Pick a number of walks that feels useful. Weekly minutes can be adjusted later in Profile → Update Goals.").foregroundStyle(.secondary)
            Stepper("Walking sessions: \(profile.weeklyWalkTarget)", value: $profile.weeklyWalkTarget, in: 1...14)
                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 16)).onChange(of: profile.weeklyWalkTarget) { saveProfile() }
            HStack {
                Button("Back") { advance(to: 1) }.buttonStyle(.bordered)
                Button("Continue") { saveProfile(); advance(to: 3) }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            }.frame(maxWidth: .infinity)
        }
    }

    private var usernameStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What should we call you?").font(.largeTitle.bold())
            Text("Choose a PausePath username. You can change it later in Profile. It is only shown to other people when you choose to join a community.")
                .font(.body).foregroundStyle(.secondary)
            TextField("Your name", text: Binding(get: { profile.username ?? "" }, set: { profile.username = String($0.prefix(32)); saveProfile() }))
                .textContentType(.nickname).textInputAutocapitalization(.words).autocorrectionDisabled()
                .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("PausePath username")
            HStack {
                Button("Back") { advance(to: 2) }.buttonStyle(.bordered)
                Button("Continue") { advance(to: 4) }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            }.frame(maxWidth: .infinity)
        }
    }

    private var connectionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let’s get your walk ready").font(.largeTitle.bold())
                Text("Connect only what you want. You can skip any of these and continue; PausePath asks for location when you use a map or start a walk.")
                    .font(.body).foregroundStyle(.secondary)
            }
            setupCard(title: "Sign in with Apple", subtitle: "Needed only for shared community features and reports. You can browse and use on-device features without signing in.", icon: "person.crop.circle") {
                if account.isSignedIn {
                    Label("PausePath: \(account.sessionStatusText)",
                          systemImage: account.sessionState == .ready ? "checkmark.circle.fill" : "person.crop.circle.badge.clock")
                        .foregroundStyle(account.sessionState == .ready ? .green : .orange)
                } else {
                    SignInWithAppleButton(.continue,
                        onRequest: { request in account.prepareAppleSignIn(request) },
                        onCompletion: { result in Task { await account.completeAppleSignIn(result) } })
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 48).disabled(account.busy)
                    if account.busy { ProgressView("Signing in…") }
                    else if account.message != PausePathAccount.signedOutMessage {
                        Text(account.message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            setupCard(title: "Apple Health & Fitness", subtitle: "Optional. Available walking activity and speed can support summaries and estimates. Heart-rate data is not used to infer your goals or preferences. Health data stays on this device.", icon: "heart.text.square") {
                if health.isLoading { ProgressView("Requesting Health access…") }
                else {
                    Button(healthRequested ? "Review Health access" : "Connect Apple Health", systemImage: "heart") {
                        healthRequested = true; Task { await health.connect() }
                    }.buttonStyle(.bordered)
                    Text(health.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            setupCard(title: "Location", subtitle: "Optional until you use a location-based feature. Nearby search and route planning need location or a starting address. Live GPS runs only during an active walk while PausePath is open, and stops when paused or ended.", icon: "location") {
                if locationDiscovery.authorizationStatus == .authorizedAlways || locationDiscovery.authorizationStatus == .authorizedWhenInUse {
                    Label("Location access is available", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button(locationNeedsSettings ? "Open Location Settings" : "Allow location", systemImage: "location.fill") {
                        if locationNeedsSettings {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } else { locationDiscovery.requestLocationAccess() }
                    }.buttonStyle(.bordered)
                    Text(locationDiscovery.status).font(.caption).foregroundStyle(.secondary)
                }
                if locationDiscovery.accuracyAuthorization == .reducedAccuracy && locationDiscovery.authorizationStatus != .notDetermined {
                    Text("Precise Location is off. Nearby results and route progress may be less accurate. You can change this in Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            setupCard(title: "Daily progress recap", subtitle: "If enabled, an 8 PM reminder lets you know your walking summary is ready in My Path. It does not include route, location, or Health details.", icon: "bell") {
                if notificationEnabled {
                    Label("Daily recap reminder is on", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Turn off reminder") { notificationEnabled = false; profile.dailyRecapNotifications = false; saveProfile(); DailyRecapNotifications.disable() }.font(.caption)
                } else {
                    Button("Allow daily recap notifications", systemImage: "bell.badge") {
                        Task {
                            let enabled = await DailyRecapNotifications.enable()
                            notificationEnabled = enabled
                            profile.dailyRecapNotifications = enabled
                            notificationStatus = enabled ? "Reminder set for 8 PM. You can turn it off at any time." : "Notifications are off. Your recap is still available in My Path when you open PausePath."
                            saveProfile()
                        }
                    }.buttonStyle(.bordered)
                }
                Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
            }
            Button(action: onContinue) {
                Text("Continue to Explore").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            Button("Back to username") { advance(to: 3) }
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
            Text("You can connect or change access later in Profile. If Health has no shared data, PausePath still uses walks recorded in the app.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func stepDot(_ number: Int) -> some View {
        Circle().fill(step >= number ? Color.accentColor : Color.secondary.opacity(0.2))
            .frame(width: 9, height: 9).accessibilityLabel("Setup step \(number + 1)")
    }

    private func advance(to newStep: Int) {
        withAnimation(reduceMotion ? .linear(duration: 0) : .snappy(duration: 0.3)) { step = newStep }
    }

    private func saveProfile() {
        profileData = (try? JSONEncoder().encode(profile)) ?? profileData
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
