import SwiftUI
import AuthenticationServices
import AVKit
import UIKit
import UserNotifications

extension Notification.Name {
    static let pausePathShowProgress = Notification.Name("pausepath.showProgress")
    static let pausePathWalkRecorded = Notification.Name("pausepath.walkRecorded")
    static let pausePathJoinCommunity = Notification.Name("pausepath.joinCommunity")
    static let pausePathReplayOnboarding = Notification.Name("pausepath.replayOnboarding")
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
        if response.notification.request.identifier.hasPrefix("pausepath.group-walk.") {
            UserDefaults.standard.set(true, forKey: "pausepath.pendingInbox")
            NotificationCenter.default.post(name: .pausePathShowInbox, object: nil)
        }
        completionHandler()
    }
}

enum PausePathAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
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
    @State private var isReplayingOnboarding = false
    @State private var health = HealthActivityStore()
    @State private var account = PausePathAccount.shared
    @AppStorage("pausepath.onboarding.permissions-gate.v2.complete") private var onboardingComplete = false
    @AppStorage("pausepath.onboarding.personal-goals.v2.complete") private var personalizationComplete = false
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.appearance") private var appearanceRawValue = PausePathAppearance.light.rawValue
    private var appearance: PausePathAppearance { PausePathAppearance(rawValue: appearanceRawValue) ?? .light }
    @AppStorage("pausepath.preferences") private var preferencesData = Data()

    private let mint = PausePathPalette.background
    private let teal = PausePathPalette.teal
    private let lime = PausePathPalette.lime

    var body: some View {
        ZStack {
            if finished || exiting {
                Group {
                    if onboardingComplete && personalizationComplete && !isReplayingOnboarding {
                        ContentView(health: health)
                    } else {
                        WelcomeSetupView(account: account, health: health, profileData: $profileData, preferencesData: $preferencesData,
                                         isReplay: isReplayingOnboarding, onExitReplay: { isReplayingOnboarding = false }) {
                            onboardingComplete = true
                            personalizationComplete = true
                            isReplayingOnboarding = false
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
        .preferredColorScheme(appearance.colorScheme)
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
        .onReceive(NotificationCenter.default.publisher(for: .pausePathReplayOnboarding)) { _ in
            guard onboardingComplete && personalizationComplete else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                isReplayingOnboarding = true
            }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.openURL) private var openURL
    @State var account: PausePathAccount
    let health: HealthActivityStore
    @Binding var profileData: Data
    @Binding var preferencesData: Data
    let isReplay: Bool
    let onExitReplay: () -> Void
    let onContinue: () -> Void
    @State private var locationDiscovery = PlaceDiscovery()
    @State private var profile = PausePathProfile()
    @State private var preferences = RoutePreferences()
    @State private var step = 0
    @State private var currentFrequency: WalkingFrequency = .unsure
    @State private var selectedSampleStop: SampleStop = .bench
    @State private var helpExpanded = false
    @State private var outlookRevealed = false
    @State private var journeyProgress: CGFloat = JourneyCheckpoint.trailhead.progress
    @State private var demoRouteDrawn = false
    @State private var pinPulse = false
    @State private var demoPlayer = AVPlayer()
    @State private var healthRequested = false
    @State private var notificationEnabled = false
    @State private var notificationStatus = "Daily recaps are always available in My Path."

    private let stepCount = 12

    private enum WalkingFrequency: Int, CaseIterable {
        case unsure = -1, none = 0, once = 1, twice = 2, three = 3, fourOrMore = 4

        var title: String {
            switch self {
            case .unsure: "Not sure yet"
            case .none: "0"
            case .once: "1"
            case .twice: "2"
            case .three: "3"
            case .fourOrMore: "4+"
            }
        }

        var weeklyText: String {
            switch self {
            case .unsure: "No starting number selected"
            case .none: "No regular walks yet"
            case .once: "About one walk a week"
            case .twice: "About two walks a week"
            case .three: "About three walks a week"
            case .fourOrMore: "Four or more walks a week"
            }
        }

        var fourWeekText: String {
            switch self {
            case .unsure: "—"
            case .fourOrMore: "16+"
            default: "\(rawValue * 4)"
            }
        }
    }

    private enum SampleStop: String, CaseIterable {
        case bench = "Bench", bathroom = "Bathroom", water = "Water", cafe = "Café"

        var icon: String {
            switch self {
            case .bench: "bench"
            case .bathroom: "figure.stand"
            case .water: "drop.fill"
            case .cafe: "cup.and.saucer.fill"
            }
        }

        var detail: String {
            switch self {
            case .bench: "Backrest and shade: unknown · Last check: unknown"
            case .bathroom: "Public access: unknown · Hours: unknown"
            case .water: "Water status: unknown · Last check: unknown"
            case .cafe: "Arrival hours: unknown · Seating: may require a purchase"
            }
        }

        var mapColor: Color {
            switch self {
            case .bench: FacilityKind.bench.mapColor
            case .bathroom: FacilityKind.bathroom.mapColor
            case .water: FacilityKind.fountain.mapColor
            case .cafe: FacilityKind.cafe.mapColor
            }
        }

        var mapPosition: UnitPoint {
            switch self {
            case .bench: UnitPoint(x: 0.22, y: 0.68)
            case .bathroom: UnitPoint(x: 0.42, y: 0.38)
            case .water: UnitPoint(x: 0.64, y: 0.32)
            case .cafe: UnitPoint(x: 0.82, y: 0.25)
            }
        }
    }

    private var isDarkInsight: Bool { step == 3 }
    private var chapter: String {
        switch step {
        case 0...3: "Your starting point"
        case 4...6: "Your plan"
        default: "See PausePath in action"
        }
    }
    private var chapterNumber: Int {
        switch step {
        case 0...3: 1
        case 4...6: 2
        default: 3
        }
    }
    private var journeyCheckpoint: JourneyCheckpoint { checkpoint(for: step) }
    private func checkpoint(for step: Int) -> JourneyCheckpoint {
        switch step {
        case 0: .trailhead
        case 1...3: .bench
        case 4...6: .water
        case 7...8: .restroom
        case 9...10: .cafe
        default: .finish
        }
    }
    private var journeyDetail: String {
        switch journeyCheckpoint {
        case .trailhead: "A sample walk begins here."
        case .bench: "Tell us what makes a walk work for you."
        case .water: "Build a flexible plan for the weeks ahead."
        case .restroom: "See how routes and mapped stops appear."
        case .cafe: "Choose your name and optional connections."
        case .finish: "Review real activity when it is available."
        }
    }

    var body: some View {
        ZStack {
            (isDarkInsight ? PausePathPalette.teal : PausePathPalette.background).ignoresSafeArea()
            LinearGradient(colors: isDarkInsight
                           ? [PausePathPalette.ink.opacity(0.34), PausePathPalette.teal, PausePathPalette.teal]
                           : [PausePathPalette.teal.opacity(0.13), PausePathPalette.background,
                              PausePathPalette.lime.opacity(0.07)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.padding(.horizontal, 22).padding(.top, 12)
                    .padding(.bottom, 9)
                    .background(headerFade)
                OnboardingJourneyScene(progress: journeyProgress, checkpoint: journeyCheckpoint,
                                       detail: journeyDetail, reduceMotion: reduceMotion)
                    .frame(maxWidth: 560)
                    .frame(height: typeSize.isAccessibilitySize ? 146 : 190)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        journeyStopLabel
                        prompt
                        page
                        howThisWorks
                    }
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 22)
                }
                .scrollDismissesKeyboard(.interactively)
                .id(step)
                footer
                    .padding(.horizontal, 22)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                    .background(footerFade)
            }
        }
        .fontDesign(.rounded)
        .tint(isDarkInsight ? PausePathPalette.lime : PausePathPalette.teal)
        .sensoryFeedback(.selection, trigger: profile.goal)
        .sensoryFeedback(.selection, trigger: currentFrequency)
        .sensoryFeedback(.selection, trigger: profile.weeklyWalkTarget)
        .sensoryFeedback(.selection, trigger: profile.weeklyMinutesTarget)
        .sensoryFeedback(.selection, trigger: profile.weeklyActiveEnergyTargetKcal)
        .sensoryFeedback(.selection, trigger: selectedSampleStop)
        .task { await account.restoreSessionIfNeeded() }
        .onAppear {
            if let saved = try? JSONDecoder().decode(PausePathProfile.self, from: profileData) { profile = saved }
            if let saved = try? JSONDecoder().decode(RoutePreferences.self, from: preferencesData) { preferences = saved }
            else { profile.goal.applyRouteDefaults(to: &preferences) }
            notificationEnabled = profile.dailyRecapNotifications
            if notificationEnabled { notificationStatus = "Reminder set for 8 PM. You can turn it off any time." }
            journeyProgress = journeyCheckpoint.progress
        }
        .onChange(of: account.appleProvidedName) { _, name in
            guard let name, profile.username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return }
            profile.username = name
            saveProfile()
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { advance(to: step - 1) } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(isDarkInsight ? .white : PausePathPalette.teal)
                    .background(isDarkInsight ? .white.opacity(0.13) : PausePathPalette.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(step == 0)
            .opacity(step == 0 ? 0.35 : 1)
            .accessibilityLabel("Back")
            VStack(alignment: .leading, spacing: 7) {
                Text("CHAPTER 0\(chapterNumber) / 03  ·  \(chapter.uppercased())")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(isDarkInsight ? PausePathPalette.lime : PausePathPalette.teal)
                    .lineLimit(1).minimumScaleFactor(0.8)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(isDarkInsight ? .white.opacity(0.22) : PausePathPalette.teal.opacity(0.14))
                        Capsule().fill(PausePathPalette.lime)
                            .frame(width: proxy.size.width * CGFloat(step + 1) / CGFloat(stepCount))
                    }
                }
                .frame(height: 5)
            }
            .accessibilityLabel("Setup progress")
            .accessibilityValue("\(chapter), step \(step + 1) of \(stepCount)")
            if isReplay {
                Button(action: onExitReplay) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(isDarkInsight ? .white : PausePathPalette.teal)
                        .frame(width: 42, height: 42)
                        .background(isDarkInsight ? .white.opacity(0.13) : PausePathPalette.surface, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close onboarding replay")
            } else {
                Text("\(step + 1)/\(stepCount)")
                    .font(.caption.weight(.bold)).monospacedDigit()
                    .foregroundStyle(isDarkInsight ? .white : PausePathPalette.teal)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(isDarkInsight ? .white.opacity(0.13) : PausePathPalette.surface, in: Capsule())
            }
        }
        .frame(height: 54)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var headerFade: some View {
        LinearGradient(colors: isDarkInsight
                       ? [PausePathPalette.teal, PausePathPalette.teal.opacity(0)]
                       : [PausePathPalette.background, PausePathPalette.background.opacity(0)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
    }

    private var footerFade: some View {
        LinearGradient(colors: isDarkInsight
                       ? [PausePathPalette.teal.opacity(0), PausePathPalette.teal.opacity(0.96)]
                       : [PausePathPalette.background.opacity(0), PausePathPalette.background.opacity(0.97)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .bottom)
    }

    private var journeyStopLabel: some View {
        HStack(spacing: 7) {
            Circle().fill(journeyCheckpoint.color).frame(width: 8, height: 8)
            Text(journeyCheckpoint.title.uppercased())
                .font(.caption2.weight(.heavy)).tracking(1.2)
            Spacer()
            Text(journeyCheckpoint == .trailhead ? "THE START" : journeyCheckpoint == .finish ? "THE FINISH" : "A PLACE TO PAUSE")
                .font(.caption2.weight(.semibold)).tracking(0.5)
        }
        .foregroundStyle(isDarkInsight ? .white.opacity(0.86) : PausePathPalette.teal)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var prompt: some View {
        VStack(alignment: typeSize.isAccessibilitySize ? .leading : .center, spacing: 9) {
            Text(title)
                .font(.system(size: typeSize.isAccessibilitySize ? 30 : 34, weight: .bold, design: .rounded))
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
                .foregroundStyle(isDarkInsight ? .white : PausePathPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.subheadline)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .center)
                .foregroundStyle(isDarkInsight ? .white.opacity(0.78) : PausePathPalette.ink.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .center)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch step {
        case 0: "PausePath"
        case 1: "What brings you outside?"
        case 2: "What does a week look like?"
        case 3: "This is where you begin."
        case 4: "Choose your walking rhythm."
        case 5: "What else matters to you?"
        case 6: "See the plan take shape."
        case 7: "Watch a walk unfold."
        case 8: "Find a place to pause."
        case 9: "What should we call you?"
        case 10: "Make it yours."
        default: "Now the real story begins."
        }
    }

    private var subtitle: String {
        switch step {
        case 0: "A route can feel different when you know where you can stop."
        case 1: "Your answer shapes the routes we suggest."
        case 2: "Tell us about a typical week, or leave it open."
        case 3: "Just your answer, shown back to you."
        case 4: "Set a flexible goal for the weeks ahead."
        case 5: "Add a time goal or an optional Health energy goal."
        case 6: "Your answers become a simple four-week view."
        case 7: "A sample shows how a route becomes a guided walk."
        case 8: "Tap a pin and watch the next pause change."
        case 9: "Use a name you’ll recognize."
        case 10: "Choose the connections you want to use."
        default: "Recorded activity can tell your story over time."
        }
    }

    @ViewBuilder private var page: some View {
        Group {
            switch step {
            case 0: introductionStep
            case 1: goalStep
            case 2: frequencyStep
            case 3: startingPointStep
            case 4: weeklyStep
            case 5: extraGoalsStep
            case 6: outlookStep
            case 7: walkthroughStep
            case 8: sampleStopStep
            case 9: nameStep
            case 10: connectionStep
            default: activityBaselineStep
            }
        }
        .id(step)
        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                        removal: .move(edge: .leading).combined(with: .opacity)))
    }

    private var howThisWorks: some View {
        DisclosureGroup(isExpanded: $helpExpanded) {
            Text(helpText)
                .font(.caption)
                .foregroundStyle(isDarkInsight ? .white.opacity(0.82) : PausePathPalette.ink.opacity(0.76))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        } label: {
            Label("How this works", systemImage: "info.circle")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isDarkInsight ? .white.opacity(0.85) : PausePathPalette.teal)
        .padding(.horizontal, 5)
    }

    private var helpText: String {
        switch step {
        case 0, 1: "PausePath helps you plan around distance, terrain, and mapped places to rest. It does not assess recovery readiness or safe exertion; medical decisions stay with your healthcare provider."
        case 2, 3: "This starting number comes only from your answer. It is not a Health record or a measure of your ability. You can leave it unknown."
        case 4, 6: "The four-week view is simple arithmetic based on your chosen weekly goal, not a forecast. Change the goal any time; a missed week is not a failure or a medical signal."
        case 5: "Active energy is an optional personal goal. Only available Apple Health readings can show progress; route plans cannot predict calories burned. Apple Health daily totals may include activity beyond walks. Neither goal is a medical target."
        case 7, 8: "These are demonstrations, not live routes. Real places, accessibility, hours, and community checks depend on available map data. Unknown information stays marked unknown."
        case 9: "This name stays on your device until you choose to use community features. A searchable username requires a separate opt-in."
        case 11: "This is a starting point, not a promise of improvement. PausePath will compare recorded walking workouts over time. Missing Health records stay unknown. The exponential curve in the research model describes a scenario; it does not prove the app caused a change."
        default: "All connections are optional. Health data stays on your device. Location is requested only when you choose it; you can search other areas without it."
        }
    }

    private var introductionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Take a short sample walk with us. At each pause, choose what matters to you and see how PausePath can help you plan.")
                .font(.body)
                .foregroundStyle(PausePathPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 8) {
                featurePill("Real walking routes", icon: "map")
                featurePill("Places to pause", icon: "bench")
            }
        }
    }

    private func featurePill(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            symbol(icon, size: 18)
            Text(title).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(PausePathPalette.teal.opacity(0.08)))
    }

    private var goalStep: some View {
        VStack(spacing: 10) {
            ForEach(PersonalGoalProfile.allCases, id: \.self) { goal in
                selectionCard(title: displayTitle(for: goal), subtitle: shortDescription(for: goal),
                              icon: icon(for: goal), selected: profile.goal == goal) {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                        profile.goal = goal
                        goal.applyRouteDefaults(to: &preferences)
                    }
                    saveProfile(); savePreferences()
                }
            }
        }
    }

    private func icon(for goal: PersonalGoalProfile) -> String {
        switch goal {
        case .recovery: "figure.walk"
        case .beginner: "figure.walk.motion"
        case .seniorFriendly: "bench"
        case .chronicPain: "leaf"
        case .generalFitness: "heart"
        case .eventTraining: "flag.checkered"
        }
    }

    private func shortDescription(for goal: PersonalGoalProfile) -> String {
        switch goal {
        case .recovery: "Shorter walks and more rest stops"
        case .beginner: "Approachable walks, one step at a time"
        case .seniorFriendly: "Flatter routes with frequent pauses"
        case .chronicPain: "Flexible walks with nearby stops"
        case .generalFitness: "Distance and route variety"
        case .eventTraining: "Longer walks for your own training"
        }
    }

    private func displayTitle(for goal: PersonalGoalProfile) -> String {
        switch goal {
        case .recovery: "After an injury"
        case .beginner: "Build a routine"
        case .seniorFriendly: "Comfortable walks"
        case .chronicPain: "Chronic pain"
        case .generalFitness: "Wellbeing & fitness"
        case .eventTraining: "Event or sport training"
        }
    }

    private var frequencyStep: some View {
        VStack(spacing: 14) {
            setupCard(title: "Typical week", subtitle: "", icon: "calendar") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 82))], spacing: 10) {
                    ForEach(WalkingFrequency.allCases.filter { $0 != .unsure }, id: \.self) { answer in
                        Button {
                            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { currentFrequency = answer }
                        } label: {
                            Text(answer.title)
                                .font(.title3.weight(.bold)).monospacedDigit()
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .background(currentFrequency == answer ? PausePathPalette.lime : PausePathPalette.background,
                                            in: RoundedRectangle(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16)
                                    .strokeBorder(currentFrequency == answer ? PausePathPalette.teal : PausePathPalette.teal.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(answer.weeklyText)
                        .accessibilityAddTraits(currentFrequency == answer ? [.isSelected] : [])
                    }
                }
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { currentFrequency = .unsure }
                } label: {
                    HStack {
                        Text("Not sure yet")
                        Spacer()
                        if currentFrequency == .unsure { Image(systemName: "checkmark.circle.fill") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(15)
                    .background(currentFrequency == .unsure ? PausePathPalette.lime.opacity(0.25) : PausePathPalette.background,
                                in: RoundedRectangle(cornerRadius: 15))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(currentFrequency == .unsure ? [.isSelected] : [])
            }
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { day in
                    Capsule()
                        .fill(day < max(0, currentFrequency.rawValue) ? PausePathPalette.lime : PausePathPalette.teal.opacity(0.10))
                        .frame(maxWidth: .infinity)
                        .frame(height: 12)
                }
            }
            .padding(.horizontal, 16)
            .accessibilityHidden(true)
            Text(currentFrequency.weeklyText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PausePathPalette.teal)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity)
        }
    }

    private var startingPointStep: some View {
        VStack(spacing: 24) {
            Text(currentFrequency == .unsure ? "—" : currentFrequency.title)
                .font(.system(size: 112, weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(PausePathPalette.lime)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.75)
            Text(currentFrequency == .unsure ? "No number needed" : "walks in a typical week")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            HStack(spacing: 9) {
                ForEach(0..<7, id: \.self) { index in
                    Capsule()
                        .fill(index < max(currentFrequency.rawValue, 0) ? PausePathPalette.lime : .white.opacity(0.22))
                        .frame(maxWidth: .infinity).frame(height: 13)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12)
            Text("YOUR FOCUS  ·  \(displayTitle(for: profile.goal).uppercased())")
                .font(.caption.weight(.bold)).tracking(0.6)
                .foregroundStyle(.white.opacity(0.8))
            Text("Next, you’ll choose where you want to go from here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 48)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 30))
        .overlay(RoundedRectangle(cornerRadius: 30).strokeBorder(.white.opacity(0.12)))
    }

    private func changeWeeklyGoal(by amount: Int) {
        let updated = min(14, max(1, profile.weeklyWalkTarget + amount))
        withAnimation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78)) {
            profile.weeklyWalkTarget = updated
        }
        saveProfile()
    }

    private var weeklyStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 22) {
                HStack(alignment: .center, spacing: 8) {
                    Button { changeWeeklyGoal(by: -1) } label: {
                        Image(systemName: "minus")
                            .font(.title2.weight(.bold))
                            .frame(width: 52, height: 52)
                            .background(PausePathPalette.background, in: Circle())
                    }
                    .disabled(profile.weeklyWalkTarget == 1)
                    .accessibilityLabel("Decrease weekly goal")
                    Spacer(minLength: 0)
                    VStack(spacing: 2) {
                        Text("\(profile.weeklyWalkTarget)")
                            .font(.system(size: 76, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("walks each week")
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    Button { changeWeeklyGoal(by: 1) } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.bold))
                            .frame(width: 52, height: 52)
                            .background(PausePathPalette.lime, in: Circle())
                    }
                    .disabled(profile.weeklyWalkTarget == 14)
                    .accessibilityLabel("Increase weekly goal")
                }
                .foregroundStyle(PausePathPalette.teal)
                HStack(spacing: 5) {
                    ForEach(0..<min(profile.weeklyWalkTarget, 14), id: \.self) { _ in
                        Capsule().fill(PausePathPalette.lime).frame(maxWidth: .infinity, minHeight: 8, maxHeight: 8)
                    }
                }
                .frame(height: 8)
                .accessibilityHidden(true)
            }
            .padding(24)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 28))
        }
    }

    private var extraGoalsStep: some View {
        VStack(spacing: 13) {
            setupCard(title: "Walking time", subtitle: "A weekly goal you can edit in My Path.", icon: "clock") {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(profile.weeklyMinutesTarget)")
                        .font(.system(size: 39, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("min / week").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(PausePathPalette.teal)
                Slider(value: Binding(get: { Double(profile.weeklyMinutesTarget) }, set: { value in
                    profile.weeklyMinutesTarget = Int(value); saveProfile()
                }), in: 30...300, step: 15)
                .accessibilityLabel("Weekly walking minutes goal")
            }
            setupCard(title: "Active calories", subtitle: "Optional · Apple Health readings only.", icon: "flame") {
                Toggle("Set a weekly goal", isOn: Binding(get: {
                    profile.weeklyActiveEnergyTargetKcal != nil
                }, set: { enabled in
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) {
                        profile.weeklyActiveEnergyTargetKcal = enabled ? 500 : nil
                    }
                    saveProfile()
                }))
                if let target = profile.weeklyActiveEnergyTargetKcal {
                    Stepper(value: Binding(get: { target }, set: { value in
                        profile.weeklyActiveEnergyTargetKcal = value; saveProfile()
                    }), in: 100...5000, step: 50) {
                        Text("\(target) active kcal / week")
                            .font(.title3.weight(.bold)).foregroundStyle(PausePathPalette.teal)
                    }
                }
            }
            Text("Planned routes do not estimate calories burned.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var outlookStep: some View {
        VStack(spacing: 15) {
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("STARTING RHYTHM")
                        .font(.caption2.weight(.heavy)).tracking(1)
                    Text(currentFrequency.fourWeekText)
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                    Text("in 4 weeks")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.headline.weight(.bold))
                    .padding(.bottom, 28)
                VStack(alignment: .leading, spacing: 7) {
                    Text("CHOSEN GOAL")
                        .font(.caption2.weight(.heavy)).tracking(1)
                    Text(outlookRevealed ? "\(profile.weeklyWalkTarget * 4)" : "0")
                        .font(.system(size: 48, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("in 4 weeks")
                        .font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(PausePathPalette.ink)
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 28))
            HStack(spacing: 8) {
                ForEach(1...4, id: \.self) { week in
                    VStack(spacing: 8) {
                        Text("WEEK \(week)")
                            .font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Capsule()
                            .fill(PausePathPalette.lime)
                            .frame(height: outlookRevealed ? CGFloat(24 + profile.weeklyWalkTarget * 3) : 8)
                        Text("\(profile.weeklyWalkTarget)")
                            .font(.headline.weight(.bold)).monospacedDigit().foregroundStyle(PausePathPalette.teal)
                    }
                    .frame(maxWidth: .infinity, minHeight: 116, alignment: .bottom)
                    .padding(.horizontal, 7).padding(.vertical, 12)
                    .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 17))
                }
            }
            HStack(spacing: 7) {
                Label("\(profile.weeklyMinutesTarget) min/week", systemImage: "clock")
                if let target = profile.weeklyActiveEnergyTargetKcal {
                    Text("·")
                    Label("\(target) active kcal/week", systemImage: "flame")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PausePathPalette.teal)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            Text("Illustration from your answers, not recorded or predicted activity.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            outlookRevealed = false
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(0.1)) { outlookRevealed = true }
        }
    }

    private var walkthroughStep: some View {
        VStack(spacing: 15) {
            if let videoURL = Bundle.main.url(forResource: "PausePathWalkthrough", withExtension: "mp4") {
                VideoPlayer(player: demoPlayer)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 27))
                    .overlay(RoundedRectangle(cornerRadius: 27).strokeBorder(PausePathPalette.teal.opacity(0.13)))
                    .accessibilityLabel("Sample video: set distance, terrain, and rest stops; review a route; see the next planned pause")
                    .onAppear {
                        if demoPlayer.currentItem == nil {
                            demoPlayer.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
                        }
                        demoPlayer.seek(to: .zero)
                        demoPlayer.isMuted = true
                        if !reduceMotion { demoPlayer.play() }
                    }
                    .onDisappear { demoPlayer.pause() }
                    .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
                        demoPlayer.seek(to: .zero)
                        if !reduceMotion { demoPlayer.play() }
                    }
                Button("Replay walkthrough", systemImage: "arrow.counterclockwise") {
                    demoPlayer.seek(to: .zero)
                    demoPlayer.play()
                }
                .font(.subheadline.weight(.semibold))
            } else {
                Label("Walkthrough unavailable in this build", systemImage: "video.slash")
                    .frame(maxWidth: .infinity, minHeight: 250)
                    .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 27))
            }
            Label("Illustrative route · no live location or facility guarantee", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sampleStopStep: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                ZStack(alignment: .topLeading) {
                    Color(red: 0.89, green: 0.95, blue: 0.91)
                    Path { path in
                        for x in stride(from: CGFloat(0), through: width, by: 42) {
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
                        }
                        for y in stride(from: CGFloat(0), through: height, by: 42) {
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: width, y: y))
                        }
                    }
                    .stroke(PausePathPalette.teal.opacity(0.09), lineWidth: 1)
                    OnboardingRouteLine(layout: .demo)
                        .stroke(.white, style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                    OnboardingRouteLine(layout: .demo)
                        .trim(from: 0, to: demoRouteDrawn ? 1 : 0)
                        .stroke(PausePathPalette.teal, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    Text("DEMO MAP · NOT LIVE")
                        .font(.caption2.weight(.heavy)).tracking(1)
                        .foregroundStyle(PausePathPalette.teal)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(.white, in: Capsule())
                        .padding(14)
                    ForEach(SampleStop.allCases, id: \.self) { stop in
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.73)) {
                                selectedSampleStop = stop
                            }
                        } label: {
                            ZStack {
                                if selectedSampleStop == stop && !reduceMotion {
                                    Circle().fill(stop.mapColor.opacity(0.22))
                                        .frame(width: pinPulse ? 74 : 56, height: pinPulse ? 74 : 56)
                                }
                                Circle().fill(.white).frame(width: selectedSampleStop == stop ? 58 : 50)
                                    .shadow(color: .black.opacity(0.17), radius: 7, y: 3)
                                Circle().fill(stop.mapColor).frame(width: selectedSampleStop == stop ? 48 : 42)
                                if stop == .bench {
                                    BenchSymbol().fill(.white).frame(width: 25, height: 25)
                                } else {
                                    Image(systemName: stop.icon)
                                        .font(.system(size: 21, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .frame(width: 60, height: 60)
                        }
                        .buttonStyle(.plain)
                        .position(x: width * stop.mapPosition.x, y: height * stop.mapPosition.y)
                        .accessibilityLabel("Preview \(stop.rawValue.lowercased()) details")
                        .accessibilityAddTraits(selectedSampleStop == stop ? [.isSelected] : [])
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28))
            }
            .frame(height: 270)
            .onAppear {
                demoRouteDrawn = reduceMotion
                pinPulse = false
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.1)) { demoRouteDrawn = true }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pinPulse = true }
            }
            VStack(alignment: .leading, spacing: 9) {
                Capsule().fill(PausePathPalette.teal.opacity(0.18))
                    .frame(width: 38, height: 4).frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    Circle().fill(selectedSampleStop.mapColor).frame(width: 12, height: 12)
                    Text(selectedSampleStop.rawValue)
                        .font(.headline).foregroundStyle(PausePathPalette.ink)
                    Spacer()
                    Text("EXAMPLE")
                        .font(.caption2.weight(.heavy)).tracking(0.7)
                        .foregroundStyle(PausePathPalette.teal)
                }
                Text(selectedSampleStop.detail)
                    .font(.subheadline).foregroundStyle(PausePathPalette.ink.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 19).padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 9)
            .offset(y: -15)
        }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("Hello, \(onboardingName).")
                    .font(.title2.weight(.bold)).foregroundStyle(PausePathPalette.teal)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .background(PausePathPalette.lime.opacity(0.22), in: RoundedRectangle(cornerRadius: 24))
            setupCard(title: "Your name in PausePath", subtitle: "", icon: "person.crop.circle") {
                TextField("Your name", text: Binding(get: { profile.username ?? "" }, set: {
                    profile.username = String($0.prefix(32)); saveProfile()
                }))
                .textContentType(.nickname)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.title3.weight(.semibold))
                .padding(14)
                .background(PausePathPalette.background, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("PausePath name")
            }
        }
    }

    private var stopReportsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(PausePathPalette.teal)
                .frame(width: 64, height: 64)
                .background(PausePathPalette.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
                .accessibilityHidden(true)
            Text("See a stop that’s missing or out of date?")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("Suggest a missing stop", systemImage: "exclamationmark.bubble")
                    .font(.headline)
                Text("On the map, tap the ! button to suggest a bench, restroom, water fountain, or café at the map center.")
                    .font(.body).foregroundStyle(.secondary)
                Label("Report a stop that’s already listed", systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Text("Open its map details and tap Report if it’s broken, closed, or no longer there.")
                    .font(.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Reports are reviewed before suggestions are shared. Sign in with Apple to submit one. Only report places you’ve checked yourself.")
                    .font(.callout)
                Text("A suggestion includes the pinned map location and stop type. A name is optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Button("Back") { advance(to: 3) }.buttonStyle(.bordered)
                Button("Continue") { advance(to: 5) }
                    .buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            }.frame(maxWidth: .infinity)
        }
    }

    private var connectionStep: some View {
        VStack(spacing: 12) {
            setupCard(title: "Sign in with Apple", subtitle: "Only needed for shared groups and reports.", icon: "person.crop.circle") {
                if account.isSignedIn {
                    Label("Connected · \(account.sessionStatusText)", systemImage: "checkmark.circle.fill")
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
            setupCard(title: "Apple Health", subtitle: "Optional walking history and speed for estimates. Health data stays on your device.", icon: "heart.text.square") {
                Button(healthRequested ? "Review Health access" : "Connect Apple Health") {
                    healthRequested = true; Task { await health.connect() }
                }.buttonStyle(.bordered).disabled(health.isLoading)
                if health.isLoading { ProgressView("Requesting Health access…") }
                else { Text(health.status).font(.caption).foregroundStyle(.secondary) }
            }
            setupCard(title: "Location", subtitle: "You can search any area without sharing your location.", icon: "location") {
                if locationDiscovery.authorizationStatus == .authorizedAlways || locationDiscovery.authorizationStatus == .authorizedWhenInUse {
                    Label("Location access is available", systemImage: "checkmark.circle.fill")
                } else {
                    Button(locationNeedsSettings ? "Open Location Settings" : "Allow location") {
                        if locationNeedsSettings {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } else { locationDiscovery.requestLocationAccess() }
                    }.buttonStyle(.bordered)
                }
                if locationDiscovery.accuracyAuthorization == .reducedAccuracy && locationDiscovery.authorizationStatus != .notDetermined {
                    Text("Precise Location is off. Nearby results and live route progress may be less accurate.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            setupCard(title: "Daily recap reminder", subtitle: "An optional 8 PM reminder; your recap stays available in My Path.", icon: "bell") {
                if notificationEnabled {
                    Label("Reminder is on", systemImage: "checkmark.circle.fill")
                    Button("Turn off reminder") {
                        notificationEnabled = false; profile.dailyRecapNotifications = false
                        saveProfile(); DailyRecapNotifications.disable()
                    }.font(.caption)
                } else {
                    Button("Allow recap reminder") {
                        Task {
                            let enabled = await DailyRecapNotifications.enable()
                            notificationEnabled = enabled
                            profile.dailyRecapNotifications = enabled
                            notificationStatus = enabled ? "Reminder set for 8 PM." : "Notifications remain off. Your recap is still in My Path."
                            saveProfile()
                        }
                    }.buttonStyle(.bordered)
                }
                Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var activityBaselineStep: some View {
        let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: .now) ?? .distantPast
        let recentWalks = health.activities.filter { $0.kind == "Walking" && $0.date >= cutoff }
        let minutes = recentWalks.reduce(0.0) { $0 + max(0, $1.seconds) } / 60
        let sample = ActivityGrowthModel.illustrativeSample

        return VStack(spacing: 12) {
            setupCard(title: "A sample user’s path", subtitle: "Illustrative model · 8 weeks", icon: "chart.xyaxis.line") {
                ActivityGrowthChart(model: sample)
                    .frame(height: 112)
                    .padding(.vertical, 4)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("BEFORE").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                    Text(sample.baselineMinutesPerDay, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "arrow.right").font(.subheadline.bold()).foregroundStyle(PausePathPalette.teal)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("WEEK 8 · MODELED").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(sample.predictedMinutesPerDay(atWeek: sample.horizonWeeks), format: .number.precision(.fractionLength(1)))
                            .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                }
                Text("min/day · modeled 8-week average: \(sample.averageMinutesPerDay(), format: .number.precision(.fractionLength(1))) min/day")
                    .font(.caption).foregroundStyle(.secondary)
                Label("Fictional example—not an average result or a promise.", systemImage: "sparkles")
                    .font(.caption2.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
                    .padding(.top, 3)
                DisclosureGroup("How the curve is calculated") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("m(t) = b + A(1 − e⁻ᵏᵗ)").font(.system(.body, design: .serif).weight(.semibold))
                        Text("For this example: b = 12 min/day, A = 10 min/day, k = 0.25/week, t = 8 weeks.")
                        Text("Average₀–₈ = 1/8 ∫₀⁸ m(t) dt = b + A[1 − (1 − e⁻⁸ᵏ)/(8k)]")
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                }
                .font(.caption.weight(.semibold))
            }

            setupCard(title: "Your starting point", subtitle: "Apple Health walking workouts · last 28 days", icon: "figure.walk") {
                if health.hasConnected && !recentWalks.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(minutes.formatted(.number.precision(.fractionLength(0))))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit().contentTransition(.numericText())
                        Text("recorded min · \(recentWalks.count) workouts")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    Text("This is your recorded workout time, not a complete measure of every walk.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if health.hasConnected {
                    Label("No walking workouts recorded", systemImage: "minus.circle")
                        .font(.headline)
                    Text("That does not mean you did not walk. Health data may be incomplete or unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("No Health baseline available", systemImage: "minus.circle")
                        .font(.headline)
                    Text("You can continue without connecting Health. Missing records are not treated as zero.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        healthRequested = true
                        Task { await health.connect() }
                    } label: {
                        Label(health.isLoading ? "Connecting…" : "Connect Apple Health", systemImage: "heart.text.square")
                    }
                    .buttonStyle(.bordered)
                    .disabled(health.isLoading)
                }
            }

            Text("Keep walking with PausePath, then check Insights for your recorded trend. Your real progress may look different from the sample.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: health.activities.count)
    }

    private var footer: some View {
        Button {
            saveProfile(); savePreferences()
            if step == stepCount - 1 { onContinue() }
            else { advance(to: step + 1) }
        } label: {
            HStack {
                Spacer()
                Text(continueTitle)
                    .font(.headline)
                Image(systemName: "arrow.right").font(.subheadline.weight(.bold))
                Spacer()
            }
            .foregroundStyle(PausePathPalette.ink)
            .frame(minHeight: 58)
            .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 19))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var continueTitle: String {
        switch step {
        case 0: "Walk to the bench"
        case 2: "See my starting point"
        case 3: "Continue to water"
        case 5: "See my four-week plan"
        case 6: "Continue to restroom"
        case 7: "Try the stops"
        case 8: "Continue to café"
        case 10: "Reach the finish"
        case 11: "Start exploring"
        default: "Continue"
        }
    }

    private func selectionCard(title: String, subtitle: String?, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                symbol(icon, size: 20)
                    .frame(width: 40, height: 40)
                    .background(PausePathPalette.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.bold)).foregroundStyle(PausePathPalette.ink)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.body).foregroundStyle(selected ? PausePathPalette.teal : .secondary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? PausePathPalette.lime.opacity(0.19) : PausePathPalette.surface,
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).strokeBorder(selected ? PausePathPalette.teal : PausePathPalette.teal.opacity(0.08), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func setupCard<Content: View>(title: String, subtitle: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                symbol(icon, size: 21)
                Text(title).font(.headline)
            }
            .foregroundStyle(PausePathPalette.teal)
            if !subtitle.isEmpty {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(PausePathPalette.teal.opacity(0.08)))
    }

    @ViewBuilder private func symbol(_ name: String, size: CGFloat) -> some View {
        if name == "bench" {
            BenchSymbol().fill(PausePathPalette.teal).frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(PausePathPalette.teal)
                .frame(width: size, height: size)
        }
    }

    private func advance(to newStep: Int) {
        guard (0..<stepCount).contains(newStep) else { return }
        helpExpanded = false
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) {
            journeyProgress = checkpoint(for: newStep).progress
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { step = newStep }
    }

    private func saveProfile() { profileData = (try? JSONEncoder().encode(profile)) ?? profileData }
    private func savePreferences() { preferencesData = (try? JSONEncoder().encode(preferences)) ?? preferencesData }
    private var onboardingName: String {
        let value = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "walker" : value
    }
    private var locationNeedsSettings: Bool {
        locationDiscovery.authorizationStatus == .denied || locationDiscovery.authorizationStatus == .restricted
    }
}

private enum JourneyCheckpoint: String, CaseIterable, Identifiable {
    case trailhead, bench, water, restroom, cafe, finish

    var id: String { rawValue }
    var progress: CGFloat {
        switch self {
        case .trailhead: 0
        case .bench: 0.2
        case .water: 0.4
        case .restroom: 0.6
        case .cafe: 0.8
        case .finish: 1
        }
    }
    var title: String {
        switch self {
        case .trailhead: "Trailhead"
        case .bench: "Bench"
        case .water: "Water stop"
        case .restroom: "Restroom"
        case .cafe: "Café"
        case .finish: "Finish"
        }
    }
    var symbol: String {
        switch self {
        case .trailhead: "figure.walk"
        case .bench: "bench"
        case .water: "drop.fill"
        case .restroom: "figure.stand"
        case .cafe: "cup.and.saucer.fill"
        case .finish: "flag.checkered"
        }
    }
    var color: Color {
        switch self {
        case .trailhead, .finish: PausePathPalette.lime
        case .bench: FacilityKind.bench.mapColor
        case .water: FacilityKind.fountain.mapColor
        case .restroom: FacilityKind.bathroom.mapColor
        case .cafe: FacilityKind.cafe.mapColor
        }
    }
}

private struct OnboardingJourneyScene: View {
    let progress: CGFloat
    let checkpoint: JourneyCheckpoint
    let detail: String
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24).fill(PausePathPalette.teal)
            AdventureContours()
                .stroke(.white.opacity(0.08), lineWidth: 1)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            GeometryReader { geometry in
                let mapRect = CGRect(x: 0, y: 0, width: geometry.size.width, height: geometry.size.height)
                JourneyCurve()
                    .stroke(.white.opacity(0.38), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [5, 7]))
                JourneyCurve()
                    .trim(from: 0, to: progress)
                    .stroke(PausePathPalette.lime, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                ForEach(JourneyCheckpoint.allCases.filter { $0 != .trailhead }) { stop in
                    JourneyStopPin(stop: stop, selected: stop == checkpoint)
                        .position(JourneyCurve.point(at: stop.progress, in: mapRect))
                }
                JourneyWalker(progress: progress)
            }
            .padding(.horizontal, 18)
            .padding(.top, 34)
            .padding(.bottom, 46)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("A SAMPLE WALK")
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(PausePathPalette.lime)
                    Spacer()
                    Text("DEMO · NOT LIVE")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.76))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(checkpoint.title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Text("·  \(detail)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sample walking route. At \(checkpoint.title). \(detail)")
        .accessibilityHint(reduceMotion ? "Route progress changes without animation." : "The walker moves to each stop as you continue.")
    }
}

private struct JourneyStopPin: View {
    let stop: JourneyCheckpoint
    let selected: Bool

    var body: some View {
        ZStack {
            Circle().fill(stop.color.opacity(selected ? 0.30 : 0.16))
                .frame(width: selected ? 43 : 34, height: selected ? 43 : 34)
            Circle().fill(stop.color)
                .frame(width: 29, height: 29)
                .overlay {
                    Group {
                        if stop == .bench {
                            BenchSymbol().fill(PausePathPalette.ink).frame(width: 16, height: 16)
                        } else {
                            Image(systemName: stop.symbol)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(PausePathPalette.ink)
                        }
                    }
                }
        }
        .frame(width: 44, height: 44)
    }
}

private struct JourneyCurve: Shape {
    private static let nodes: [CGPoint] = [
        CGPoint(x: 0.08, y: 0.68), CGPoint(x: 0.25, y: 0.35),
        CGPoint(x: 0.42, y: 0.67), CGPoint(x: 0.59, y: 0.35),
        CGPoint(x: 0.76, y: 0.68), CGPoint(x: 0.92, y: 0.35)
    ]

    func path(in rect: CGRect) -> Path {
        Path { path in
            guard let first = Self.nodes.first else { return }
            path.move(to: CGPoint(x: rect.minX + rect.width * first.x, y: rect.minY + rect.height * first.y))
            for index in 1..<Self.nodes.count {
                let start = Self.nodes[index - 1]
                let end = Self.nodes[index]
                let middleX = (start.x + end.x) / 2
                path.addCurve(
                    to: CGPoint(x: rect.minX + rect.width * end.x, y: rect.minY + rect.height * end.y),
                    control1: CGPoint(x: rect.minX + rect.width * middleX, y: rect.minY + rect.height * start.y),
                    control2: CGPoint(x: rect.minX + rect.width * middleX, y: rect.minY + rect.height * end.y)
                )
            }
        }
    }

    static func point(at progress: CGFloat, in rect: CGRect) -> CGPoint {
        let route = JourneyCurve().path(in: rect)
        return route.trimmedPath(from: 0, to: min(max(progress, 0.0001), 1)).currentPoint
            ?? CGPoint(x: rect.minX + rect.width * nodes[0].x, y: rect.minY + rect.height * nodes[0].y)
    }
}

private struct JourneyWalker: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let location = JourneyCurve.point(at: progress, in: CGRect(origin: .zero, size: geometry.size))
            Image(systemName: "figure.walk")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(PausePathPalette.ink)
                .frame(width: 32, height: 32)
                .background(PausePathPalette.lime, in: Circle())
                .overlay(Circle().strokeBorder(PausePathPalette.teal, lineWidth: 2))
                .position(x: location.x + 7, y: location.y - 23)
        }
    }
}

private struct OnboardingRouteLine: Shape {
    enum Layout { case demo }
    let layout: Layout

    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height
        return Path { path in
            switch layout {
            case .demo:
                path.move(to: CGPoint(x: width * 0.08, y: height * 0.86))
                path.addCurve(to: CGPoint(x: width * 0.44, y: height * 0.42),
                              control1: CGPoint(x: width * 0.48, y: height * 0.85),
                              control2: CGPoint(x: width * 0.18, y: height * 0.36))
                path.addCurve(to: CGPoint(x: width * 0.9, y: height * 0.18),
                              control1: CGPoint(x: width * 0.84, y: height * 0.48),
                              control2: CGPoint(x: width * 0.56, y: height * 0.13))
            }
        }
    }
}

struct ActivityGrowthChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0
    let model: ActivityGrowthModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let values = (0...32).map { index in
                model.predictedMinutesPerDay(atWeek: model.horizonWeeks * Double(index) / 32)
            }
            let low = model.baselineMinutesPerDay
            let high = max(low + 1, values.last ?? low + 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                        y: size.height - 12 - (size.height - 26) * CGFloat((value - low) / (high - low)))
            }
            ZStack(alignment: .bottomLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height - 12))
                    path.addLine(to: CGPoint(x: size.width, y: size.height - 12))
                }.stroke(PausePathPalette.teal.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .trim(from: 0, to: reveal)
                .stroke(PausePathPalette.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                if let first = points.first, let last = points.last {
                    Circle().fill(PausePathPalette.teal).frame(width: 9, height: 9).position(first)
                    Circle().fill(PausePathPalette.lime).overlay(Circle().stroke(PausePathPalette.teal, lineWidth: 2))
                        .frame(width: 13, height: 13).position(last)
                }
                HStack {
                    Text("WEEK 0"); Spacer(); Text("WEEK 8")
                }
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 0)
            }
        }
        .accessibilityLabel("Illustrative exponential model: walking time gradually rises from 12 minutes per day at week zero to about 20.6 at week eight")
        .onAppear {
            if reduceMotion { reveal = 1 }
            else { withAnimation(.easeOut(duration: 1.1)) { reveal = 1 } }
        }
    }
}

struct BenchSymbol: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height)
        let x = rect.midX - unit / 2
        let y = rect.midY - unit / 2
        var path = Path()
        path.addRoundedRect(in: CGRect(x: x + unit * 0.13, y: y + unit * 0.10,
                                       width: unit * 0.74, height: unit * 0.39),
                            cornerSize: CGSize(width: unit * 0.07, height: unit * 0.07))
        path.addRoundedRect(in: CGRect(x: x + unit * 0.05, y: y + unit * 0.55,
                                       width: unit * 0.90, height: unit * 0.16),
                            cornerSize: CGSize(width: unit * 0.04, height: unit * 0.04))
        path.addRoundedRect(in: CGRect(x: x + unit * 0.18, y: y + unit * 0.68,
                                       width: unit * 0.10, height: unit * 0.23),
                            cornerSize: CGSize(width: unit * 0.02, height: unit * 0.02))
        path.addRoundedRect(in: CGRect(x: x + unit * 0.72, y: y + unit * 0.68,
                                       width: unit * 0.10, height: unit * 0.23),
                            cornerSize: CGSize(width: unit * 0.02, height: unit * 0.02))
        return path
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
