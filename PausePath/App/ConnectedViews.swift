import SwiftUI
import MapKit
import AuthenticationServices

struct AccountView: View {
    @State private var account = PausePathAccount.shared
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.weather.openMeteo.guidance.enabled") private var weatherGuidanceEnabled = true
    @AppStorage("pausepath.weather.openMeteo.walkUpdates.enabled") private var weatherWalkUpdatesEnabled = true
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Image("PausePathLogo")
                        .resizable().scaledToFit().frame(height: 144)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("PausePath")
                }.listRowBackground(Color.clear)
                Section("Apple account") {
                    Text("Sign in once with Apple to use community features. Your PausePath session is saved securely on this device.").font(.callout)
                    if account.isSignedIn {
                        Label("PausePath: \(account.sessionStatusText)",
                              systemImage: account.sessionState == .ready ? "checkmark.circle.fill" : "person.crop.circle.badge.clock")
                            .font(.subheadline)
                            .foregroundStyle(account.sessionState == .ready ? Color.green : Color.orange)
                        if let email = account.email { Text(email).font(.subheadline).foregroundStyle(.secondary) }
                        if account.sessionState == .checking || account.sessionState == .temporarilyUnavailable {
                            Text(account.message).font(.caption).foregroundStyle(.secondary)
                            Button("Check account connection") { Task { await account.restoreSessionIfNeeded() } }
                                .disabled(account.sessionState == .checking)
                        }
                        Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                    } else {
                        SignInWithAppleButton(.continue) { request in
                            account.prepareAppleSignIn(request)
                        } onCompletion: { result in
                            Task { await account.completeAppleSignIn(result) }
                        }
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 50)
                        .disabled(account.busy)
                        if account.busy { ProgressView("Signing in…") }
                        else if account.message != PausePathAccount.signedOutMessage {
                            Text(account.message).font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Use your Apple Account. No PausePath password or confirmation email is needed. Apple may ask you to confirm with Face ID, Touch ID or your device passcode.").font(.caption)

                    }
                }
                Section("How connected features work") {
                    Text("Explore shares the visible map area to load OSM, community stops and Mapbox cafés. It refreshes as you move the map and once a minute while Explore is open.")
                    Text("Finding route breaks shares the planned path, departure time and stop preferences. Arrival estimates on the server use a standard walking speed. Health data and your recorded activities stay on this device.")
                    Text("Reports are linked to your account. New stops need review before appearing for others. Provider coverage and opening hours vary by location.")
                }.font(.footnote)
                Section("Map credits") {
                    Text("Facility data: © OpenStreetMap contributors (ODbL), Mapbox, and the PausePath community. Basemap and navigation: Apple Maps.")
                    Link("© OpenStreetMap contributors", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                    Link("© Mapbox", destination: URL(string: "https://www.mapbox.com/about/maps/")!)
                }.font(.footnote)
                Section("Weather guidance") {
                    Toggle("Show weather on route previews", isOn: $weatherGuidanceEnabled)
                    Toggle("Show meaningful updates while walking", isOn: $weatherWalkUpdatesEnabled)
                        .disabled(!weatherGuidanceEnabled)
                    Text("Weather guidance and meaningful walking updates are on by default. Up to three approximate route locations are sent to Open-Meteo for a seven-day forecast; walking updates check your approximate location about every 15 minutes while navigation is active and PausePath is open. Turn either option off here. Forecasts are cached in memory for 15 minutes. Open-Meteo may retain request logs for up to 90 days.")
                        .font(.footnote)
                    Text("Forecasts are estimates and can be unavailable or out of date. Shade and water-stop information is incomplete.")
                        .font(.footnote)
                }
                Section("Daily progress recap") {
                    let profile = (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile()
                    if profile.dailyRecapNotifications {
                        Label("Daily reminder is on for 8 PM", systemImage: "bell.badge.fill")
                        Button("Turn off daily reminder", role: .destructive) {
                            var updated = profile
                            updated.dailyRecapNotifications = false
                            profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                            DailyRecapNotifications.disable()
                        }
                    } else {
                        Text("Your activity recap is available in My progress when you open PausePath.")
                        Button("Allow an 8 PM reminder", systemImage: "bell.badge") {
                            Task {
                                let enabled = await DailyRecapNotifications.enable()
                                var updated = (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile()
                                updated.dailyRecapNotifications = enabled
                                profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                            }
                        }
                    }
                    Text("If enabled, an 8 PM reminder tells you when your walking summary is ready in My progress. It never includes route, location, or Health details. Manage notification access in iOS Settings at any time.").font(.footnote)
                }
            }.navigationTitle("Account")
        }
    }
}

private struct WeeklyPersonalChallenge: Codable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var kind: String
    var target: Double
    var pointsAwarded = false
}

struct CommunityChallengesView: View {
    let preferences: RoutePreferences
    @State private var account = PausePathAccount.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var communities: [WalkingCommunity] = []
    @State private var challenges: [UUID: [WalkingCommunityChallenge]] = [:]
    @State private var communityComposerMode: CommunityComposerMode?
    @AppStorage("pausepath.pendingCommunityInvite") private var pendingInviteCode = ""
    @State private var challengeSheetTarget: ChallengeTarget?
    @State private var message = ""
    @State private var communityLoadMessage: String?
    @State private var busy = false
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.shareChallengeProgress") private var shareProgress = false
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.weeklyChallengeDeck") private var weeklyChallengeData = Data()
    @AppStorage("pausepath.weeklyChallengeWeek") private var challengeWeekKey = ""
    @AppStorage("pausepath.weeklyChallengeRefreshes") private var weeklyRefreshesUsed = 0
    @AppStorage("pausepath.weeklyChallengeRefreshWeek") private var refreshWeekKey = ""
    @AppStorage("pausepath.monthlyChallengePoints") private var monthlyPoints = 0
    @AppStorage("pausepath.challengePointsMonth") private var pointsMonthKey = ""
    @State private var weeklyChallenges: [WeeklyPersonalChallenge] = []
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Walk together, if you choose.").font(.headline)
                    Text("Create a community or join with an invite code. Sharing activity is optional.")
                        .font(.callout).foregroundStyle(.secondary)
                    if account.isSignedIn {
                        HStack(spacing: 12) {
                            Button { message = ""; communityComposerMode = .create } label: { Label("Create community", systemImage: "plus") }
                                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                            Button { message = ""; communityComposerMode = .join } label: { Label("Join with code", systemImage: "number") }
                                .buttonStyle(.bordered).frame(maxWidth: .infinity)
                        }.disabled(account.busy)
                        if !message.isEmpty {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        SignInWithAppleButton(.continue,
                            onRequest: { request in account.prepareAppleSignIn(request) },
                            onCompletion: { result in Task { await account.completeAppleSignIn(result) } })
                            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                            .frame(height: 48).disabled(account.busy)
                        if account.busy {
                            ProgressView("Signing in…")
                        } else {
                            Text(account.message == PausePathAccount.signedOutMessage
                                 ? "Sign in once. Your PausePath account stays connected across tabs."
                                 : account.message)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(weeklyChallenges) { challenge in
                        let progress = weeklyProgress(for: challenge)
                        let complete = progress >= challenge.target
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(challenge.title).font(.headline)
                                Spacer(minLength: 8)
                                Text(challengeProgressLabel(challenge, progress: progress))
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(complete ? Color.accentColor : Color.secondary)
                            }
                            SegmentedChallengeProgress(value: progress, total: challenge.target)
                                .frame(height: 9)
                                .accessibilityLabel("\(challengeProgressLabel(challenge, progress: progress)) complete")
                            if complete { Label("Completed • 10 points", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                        }.padding(.vertical, 3)
                    }
                    HStack {
                        Label("\(monthlyPoints) points this month", systemImage: "star.fill")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Refresh (\(max(0, 2 - weeklyRefreshesUsed)) left)") { refreshWeeklyChallenges() }
                            .font(.caption.weight(.semibold))
                            .disabled(weeklyRefreshesUsed >= 2)
                    }
                    Text("Choose two achievable suggestions for this week. You can refresh them twice; points are awarded once when recorded walks meet a challenge. Points never depend on pace, harder routes, or heart rate.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Your challenges") }
                Section("Communities") {
                    if let communityLoadMessage {
                        Label(communityLoadMessage, systemImage: "wifi.exclamationmark")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Try loading again") { Task { await refresh() } }
                    } else if busy {
                        ProgressView("Loading communities…")
                    }
                    if !account.isSignedIn {
                        Text("Sign in with Apple to create a community or join with an invite code.")
                            .foregroundStyle(.secondary)
                    } else {
                        Toggle("Share challenge progress with my communities", isOn: $shareProgress)
                        Text("When enabled, PausePath sends only challenge totals (walk count, distance, minutes, or routes). It never shares route names, location, or Health data. Turning this off removes your totals from community boards.")
                            .font(.caption).foregroundStyle(.secondary)
                        if communities.isEmpty && communityLoadMessage == nil && !busy {
                            Text("You haven’t joined a community yet.").foregroundStyle(.secondary)
                        }
                        ForEach(communities) { community in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(community.name).font(.headline)
                                    Spacer()
                                    Text("\(community.member_count) members").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("You appear as \(community.my_display_name)").font(.caption).foregroundStyle(.secondary)
                                if let members = community.members, !members.isEmpty {
                                    Text("Members").font(.caption.weight(.semibold))
                                    Text(members.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Community members can see these usernames. They see your activity totals only while progress sharing is on; routes, locations, and Health data stay private.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Label("Invite code: \(community.invite_code)", systemImage: "number")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                ShareLink(item: "Join my PausePath community with invite code \(community.invite_code)\nOpen PausePath: pausepath://community/join?code=\(community.invite_code)") {
                                    Label("Share invite code", systemImage: "square.and.arrow.up").font(.caption.weight(.semibold))
                                }
                                if let list = challenges[community.id], !list.isEmpty {
                                    ForEach(list) { challenge in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(challenge.name).font(.subheadline.weight(.semibold))
                                            ProgressView(value: min(challenge.my_progress ?? 0, challenge.target), total: challenge.target)
                                            Text("\((challenge.my_progress ?? 0), specifier: "%.1f") / \(challenge.target, specifier: "%.1f") \(unit(challenge.metric))")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if !challenge.leaderboard.isEmpty {
                                                DisclosureGroup("Community board") {
                                                    ForEach(Array(challenge.leaderboard.prefix(10).enumerated()), id: \.offset) { index, member in
                                                        HStack {
                                                            Text("\(index + 1). \(member.name)")
                                                            Spacer()
                                                            Text("\(member.amount, specifier: "%.1f") \(unit(challenge.metric))")
                                                        }.font(.caption)
                                                    }
                                                }.font(.caption)
                                            }
                                        }.padding(.vertical, 4)
                                    }
                                } else { Text("No active tasks in this community yet.").font(.caption).foregroundStyle(.secondary) }
                                Button("Create a community task", systemImage: "plus") { challengeSheetTarget = ChallengeTarget(community.id) }
                                    .font(.subheadline)
                            }.padding(.vertical, 5)
                        }
                    }
                }
                Section {
                    Text("Take part at your own pace. A challenge is not a fitness test or medical recommendation; choose a goal that feels appropriate for you.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Challenges")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) { Image(systemName: "star.fill"); Text("\(monthlyPoints)") }
                        .font(.subheadline.weight(.semibold)).accessibilityLabel("\(monthlyPoints) points this month")
                }
            }
            .task { loadWeeklyChallenges(); if !pendingInviteCode.isEmpty { communityComposerMode = .join }; await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathWalkRecorded)) { _ in
                updateWeeklyProgress(); Task { await refresh() }
            }
            .onChange(of: account.userID) { _, userID in
                if userID != nil { Task { await refresh() } }
                else { communities = []; challenges = [:]; communityLoadMessage = nil; message = "" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathJoinCommunity)) { notification in
                pendingInviteCode = notification.userInfo?["code"] as? String ?? ""
                communityComposerMode = .join
            }
            .onChange(of: pendingInviteCode) { _, code in if !code.isEmpty { communityComposerMode = .join } }
            .onChange(of: preferences) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: profileData) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: shareProgress) { _, enabled in
                Task {
                    if enabled { await refresh() }
                    else {
                        do { try await PausePathAPI.clearChallengeProgress(); await refresh() }
                        catch { message = communityActionError(for: error) }
                    }
                }
            }
            .sheet(item: $communityComposerMode, onDismiss: { pendingInviteCode = "" }) { mode in
                CommunityComposerSheet(mode: mode, account: account, onCreate: createCommunity, onJoin: joinCommunity,
                    message: $message, initialUsername: profile.username ?? "", initialInviteCode: pendingInviteCode)
            }
            .sheet(item: $challengeSheetTarget) { target in
                ChallengeComposer(onSave: { name, metric, amount in
                    await createChallenge(communityID: target.id, name: name, metric: metric, target: amount)
                })
            }
        }
    }

    private var currentWeekKey: String {
        let parts = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        return "\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
    }
    private var currentMonthKey: String {
        let parts = Calendar.current.dateComponents([.year, .month], from: Date())
        return "\(parts.year ?? 0)-\(parts.month ?? 0)"
    }
    private func loadWeeklyChallenges() {
        if pointsMonthKey != currentMonthKey { pointsMonthKey = currentMonthKey; monthlyPoints = 0 }
        if refreshWeekKey != currentWeekKey { refreshWeekKey = currentWeekKey; weeklyRefreshesUsed = 0 }
        if challengeWeekKey == currentWeekKey,
           let decoded = try? JSONDecoder().decode([WeeklyPersonalChallenge].self, from: weeklyChallengeData), decoded.count == 2 {
            weeklyChallenges = decoded
        } else {
            weeklyChallenges = makeWeeklyDeck()
            challengeWeekKey = currentWeekKey
            weeklyRefreshesUsed = 0
            refreshWeekKey = currentWeekKey
            storeWeeklyChallenges()
        }
        updateWeeklyProgress()
    }
    private func makeWeeklyDeck(excluding: Set<String> = []) -> [WeeklyPersonalChallenge] {
        let suggestedDistance = suggestedDistanceTarget
        let ideas: [(String, String, Double)] = [
            ("Complete a PausePath walk when it suits you", "walks", 1),
            ("Try a different route this week", "new_routes", 1),
            ("Walk a distance that fits your route preferences", "distance_km", suggestedDistance),
            ("Complete two walks at your own pace", "walks", 2),
            ("Explore two routes you have not completed before", "new_routes", 2),
            ("Walk 2 km in total across completed walks", "distance_km", 2),
            ("Complete three walks whenever they fit your week", "walks", 3)
        ]
        let available = ideas.filter { !excluding.contains($0.0) }.shuffled()
        return available.prefix(2).map { WeeklyPersonalChallenge(title: $0.0, kind: $0.1, target: $0.2) }
    }
    private var suggestedDistanceTarget: Double {
        let preferredDistance = min(5, max(0.5, preferences.distanceMeters / 1_000))
        return profile.goal.prefersGentlerRoutes ? min(preferredDistance, 0.5) : preferredDistance
    }
    private func personalizeUnstartedChallenges() {
        for index in weeklyChallenges.indices where weeklyChallenges[index].kind == "distance_km" && !weeklyChallenges[index].pointsAwarded {
            guard weeklyProgress(for: weeklyChallenges[index]) == 0 else { continue }
            weeklyChallenges[index].target = suggestedDistanceTarget
        }
        storeWeeklyChallenges()
    }
    private func refreshWeeklyChallenges() {
        guard weeklyRefreshesUsed < 2 else { return }
        weeklyChallenges = makeWeeklyDeck(excluding: Set(weeklyChallenges.map(\.title)))
        weeklyRefreshesUsed += 1
        storeWeeklyChallenges()
        updateWeeklyProgress()
    }
    private func storeWeeklyChallenges() {
        weeklyChallengeData = (try? JSONEncoder().encode(weeklyChallenges)) ?? weeklyChallengeData
    }
    private func weeklyProgress(for challenge: WeeklyPersonalChallenge) -> Double {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
        let weekWalks = walks.filter { $0.completed && interval?.contains($0.date) == true }
        switch challenge.kind {
        case "distance_km": return weekWalks.reduce(0) { $0 + $1.distanceMeters / 1000 }
        // Older sessions without an opaque route identity are not guessed from a display name.
        case "new_routes": return Double(Set(weekWalks.compactMap(\.routeIdentity)).count)
        case "walks": return Double(weekWalks.count)
        default: return 0
        }
    }
    private func challengeProgressLabel(_ challenge: WeeklyPersonalChallenge, progress: Double) -> String {
        if challenge.kind == "distance_km" { return String(format: "%.1f / %.1f km", progress, challenge.target) }
        return "\(min(Int(progress), Int(challenge.target))) / \(Int(challenge.target))"
    }
    private func updateWeeklyProgress() {
        for index in weeklyChallenges.indices {
            if weeklyProgress(for: weeklyChallenges[index]) >= weeklyChallenges[index].target,
               !weeklyChallenges[index].pointsAwarded {
                weeklyChallenges[index].pointsAwarded = true
                monthlyPoints += 10
            }
        }
        storeWeeklyChallenges()
    }
    private func unit(_ metric: String) -> String {
        switch metric { case "distance_km": "km"; case "minutes": "minutes"; case "new_routes": "routes"; default: "walks" }
    }
    private func refresh() async {
        guard account.isSignedIn else { return }
        busy = true; defer { busy = false }
        do {
            if let username = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
                try await PausePathAPI.updateCommunityUsername(username)
            }
            communities = try await PausePathAPI.communities()
            for community in communities {
                let list = try await PausePathAPI.challenges(in: community.id)
                challenges[community.id] = list
                if shareProgress {
                    for challenge in list {
                        let total: Double
                        let completedWalks = walks.filter(\.completed)
                        switch challenge.metric {
                        case "distance_km": total = completedWalks.reduce(0) { $0 + $1.distanceMeters / 1000 }
                        case "minutes": total = completedWalks.reduce(0) { $0 + $1.activeSeconds / 60 }
                        case "new_routes": total = Double(Set(completedWalks.compactMap(\.routeIdentity)).count)
                        default: total = Double(completedWalks.count)
                        }
                        try await PausePathAPI.updateChallengeProgress(challenge.id, amount: total)
                    }
                    challenges[community.id] = try await PausePathAPI.challenges(in: community.id)
                }
            }
            communityLoadMessage = nil
        } catch {
            communityLoadMessage = communityLoadError(for: error)
        }
    }
    private func saveCommunityUsername(_ username: String) {
        var updated = profile; updated.username = username
        profileData = (try? JSONEncoder().encode(updated)) ?? profileData
    }
    private func createCommunity(name: String, username: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            saveCommunityUsername(username)
            let community = try await PausePathAPI.createCommunity(name: name, username: username)
            message = "Community created. Share invite code \(community.invite_code) with people you choose."
            await refresh()
            return true
        } catch { message = communityActionError(for: error); return false }
    }
    private func joinCommunity(code: String, username: String) async -> Bool {
        busy = true; defer { busy = false }
        do {
            saveCommunityUsername(username)
            let community = try await PausePathAPI.joinCommunity(code: code, username: username)
            message = "Joined \(community.name)."
            await refresh()
            return true
        } catch { message = communityActionError(for: error, joining: true); return false }
    }
    private func createChallenge(communityID: UUID, name: String, metric: String, target: Double) async -> String? {
        do {
            try await PausePathAPI.createChallenge(in: communityID, name: name, metric: metric, target: target)
            message = "Community task created. Everyone can join at their own pace."
            await refresh()
            return nil
        } catch {
            let explanation = communityActionError(for: error)
            message = explanation
            return explanation
        }
    }
    private func communityLoadError(for error: Error) -> String {
        if let failure = error as? ServiceFailure, failure.status == 404 {
            return "Community features are waiting for a server update. Try again later."
        }
        return "Couldn’t load communities right now. Check your connection and try again."
    }
    private func communityActionError(for error: Error, joining: Bool = false) -> String {
        if let failure = error as? ServiceFailure, failure.status == 404 {
            if joining, failure.message.localizedCaseInsensitiveContains("invite code") {
                return "That invite code wasn’t found. Check it and try again."
            }
            return "Community features are waiting for a server update. Try again later."
        }
        return error.localizedDescription
    }
}

private struct SegmentedChallengeProgress: View {
    let value: Double
    let total: Double
    private var count: Int { max(1, min(20, Int(total.rounded(.up)))) }
    var body: some View {
        let normalizedProgress = max(0, min(1, value / max(total, 0.0001))) * Double(count)
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                GeometryReader { geometry in
                    let segmentProgress = min(1, max(0, normalizedProgress - Double(index)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.16))
                        Capsule().fill(Color.accentColor).frame(width: geometry.size.width * segmentProgress)
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}

private struct ChallengeTarget: Identifiable { let id: UUID; init(_ id: UUID) { self.id = id } }

private enum CommunityComposerMode: String, Identifiable {
    case create
    case join
    var id: String { rawValue }
    var title: String { self == .create ? "Create community" : "Join community" }
}

private struct CommunityComposerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let mode: CommunityComposerMode
    let account: PausePathAccount
    let onCreate: (String, String) async -> Bool
    let onJoin: (String, String) async -> Bool
    @Binding var message: String
    let initialUsername: String
    let initialInviteCode: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var code = ""
    @State private var username = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if !account.isSignedIn {
                    Text("Sign in once with Apple to continue. Your route and location history stays private.")
                        .font(.callout).foregroundStyle(.secondary)
                    SignInWithAppleButton(.continue,
                        onRequest: { request in account.prepareAppleSignIn(request) },
                        onCompletion: { result in Task { await account.completeAppleSignIn(result) } })
                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                        .frame(height: 48).disabled(account.busy)
                    if account.busy {
                        ProgressView("Signing in…")
                    } else if account.message != PausePathAccount.signedOutMessage {
                        Text(account.message).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if account.sessionState != .ready {
                        Label("Your saved account will be checked when you submit.", systemImage: "person.crop.circle.badge.clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if mode == .create {
                        TextField("Community name", text: $name)
                            .textInputAutocapitalization(.words).textFieldStyle(.roundedBorder)
                    } else {
                        TextField("Invite code", text: $code)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                    }
                    TextField("Community username", text: $username)
                        .textContentType(.nickname).textInputAutocapitalization(.words).textFieldStyle(.roundedBorder)
                    Button {
                        Task {
                            busy = true
                            let succeeded: Bool
                            if mode == .create {
                                succeeded = await onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines), cleanUsername)
                            } else {
                                succeeded = await onJoin(code.trimmingCharacters(in: .whitespacesAndNewlines), cleanUsername)
                            }
                            busy = false
                            if succeeded { dismiss() }
                        }
                    } label: {
                        if busy { ProgressView() }
                        else { Text(mode == .create ? "Create community" : "Join community") }
                    }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(busy || cleanUsername.isEmpty
                        || (mode == .create && name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                        || (mode == .join && code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    if !message.isEmpty {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Members see your chosen username. Activity sharing is controlled separately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle(mode.title)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .onAppear { username = initialUsername; code = initialInviteCode }
        }
    }
    private var cleanUsername: String { String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)) }
}

private struct ChallengeComposer: View {
    let onSave: (String, String, Double) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Walk a little at your pace"
    @State private var metric = "walks"
    @State private var target = 3.0
    @State private var busy = false
    @State private var message = ""
    private let metrics = ["walks", "distance_km", "minutes", "new_routes"]
    var body: some View {
        NavigationStack {
            Form {
                Section("Make it yours") {
                    TextField("Task name", text: $name)
                    Picker("Measure progress by", selection: $metric) {
                        ForEach(metrics, id: \.self) { value in Text(metricLabel(value)).tag(value) }
                    }
                    Stepper("Goal: \(target, specifier: "%.0f") \(unit)", value: $target, in: 1...100, step: 1)
                }
                Text("Progress sharing is optional. This task appears to members of the community.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            }.navigationTitle("Community task")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            Task {
                                busy = true
                                let error = await onSave(name, metric, target)
                                busy = false
                                if let error { message = error }
                                else { dismiss() }
                            }
                        }
                            .disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
                    }
                }
        }
    }
    private var unit: String {
        switch metric { case "distance_km": "km"; case "minutes": "minutes"; case "new_routes": "routes"; default: "walks" }
    }
    private func metricLabel(_ value: String) -> String {
        switch value { case "distance_km": "Distance (km)"; case "minutes": "Moving minutes"; case "new_routes": "New routes"; default: "Walks" }
    }
}

struct StopReportView: View {
    let place: DiscoveredPlace?
    let coordinate: CLLocationCoordinate2D
    var onSaved: () -> Void = {}
    @State private var kind: FacilityKind = .bench
    @State private var name = ""
    @State private var reportType = "confirm_exists"
    @State private var message = ""
    @State private var busy = false
    @State private var submitted = false
    @State private var requestID = UUID()
    @Environment(\.dismiss) private var dismiss
    private let statuses = [("confirm_exists", "It exists and is available"), ("broken_or_empty", "Broken or empty"), ("temporarily_closed", "Temporarily closed"), ("removed", "No longer here")]
    var body: some View {
        NavigationStack {
            Form {
                if !PausePathAccount.shared.isSignedIn {
                    Text("Sign in from the Account tab to submit a report.")
                } else {
                    Section(place?.shared == nil ? "Suggest a stop" : "Report this stop") {
                        if let place, place.shared != nil {
                            Text(place.item.name ?? place.kind.rawValue)
                            Picker("What did you find?", selection: $reportType) {
                                ForEach(statuses, id: \.0) { Text($0.1).tag($0.0) }
                            }.onChange(of: reportType) { requestID = UUID() }
                        } else {
                            Text("Pin location: \(coordinate.latitude, specifier: "%.5f"), \(coordinate.longitude, specifier: "%.5f"). Close this sheet and move the map center to change it.")
                            TextField("Name (optional)", text: $name).onChange(of: name) { requestID = UUID() }
                            Picker("Facility", selection: $kind) { ForEach(FacilityKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                                .onChange(of: kind) { requestID = UUID() }
                            Text("Only submit locations you observed yourself. Suggestions are reviewed before being shared.").font(.caption)
                        }
                        Button(busy ? "Sending…" : "Submit observation") { Task { await submit() } }
                            .disabled(busy || submitted)
                    }.disabled(busy || submitted)
                }
                if !message.isEmpty { Text(message) }
            }.navigationTitle("Community report")
                .toolbar { Button("Done") { dismiss() } }
        }
    }
    private func submit() async {
        busy = true; defer { busy = false }
        var body: [String: Any] = ["request_id": requestID.uuidString]
        if let poi = place?.shared {
            body.merge(["kind":"status", "poi_id":poi.id.uuidString, "report_type":reportType]) { _, new in new }
        } else {
            body.merge(["kind":"suggestion", "category":kind.apiCategory,
                "location":["type":"Point", "coordinates":[coordinate.longitude,coordinate.latitude]]]) { _, new in new }
            if !name.isEmpty { body["name"] = String(name.prefix(200)) }
        }
        do {
            _ = try await PausePathAPI.request("api/v1/reports", body: body, requiresAccount: true)
            submitted = true
            message = place?.shared == nil ? "Suggestion sent for review." : "Report recorded. Shared stop status will update on refresh."
            onSaved()
        } catch { message = error.localizedDescription }
    }
}

struct RouteBreaksView: View {
    let walk: GeneratedWalk
    var currentLocation: CLLocationCoordinate2D?
    var onDetour: () -> Void
    var onReturn: () -> Void
    var onStopsChanged: ([SharedPOI]) -> Void
    @State private var result: CuratedResponse?
    @State private var message = ""
    @State private var busy = false
    @State private var allowUnknown = false
    @State private var detour: GeneratedWalk?
    @State private var report: DiscoveredPlace?
    @State private var latest: [UUID: SharedPOI] = [:]
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Break stops along this walk").font(.headline)
            Toggle("Include stops with unknown opening hours", isOn: $allowUnknown)
                .onChange(of: allowUnknown) { result = nil; latest = [:] }
            Text("Finding breaks shares this route and your stop preferences. Server arrival estimates use a standard walking speed; terrain and maximum seating gaps remain unverified.").font(.caption)
            Button(busy ? "Finding breaks…" : "Find / refresh break stops") { Task { await load() } }
                .disabled(busy)
            if !message.isEmpty { Text(message).font(.caption) }
            if let result {
                Text("\(result.properties.break_points.count) suggested stops • \(result.properties.unfilled_targets_meters.count) intervals without a match").font(.subheadline)
                Text("These stops are optional detours. Choose a stop for separate walking guidance; your original walk pauses until you return and resume it.").font(.caption)
                ForEach(result.properties.break_points) { stop in
                    let poi = latest[stop.id] ?? stop.poi
                    VStack(alignment: .leading, spacing: 6) {
                        Text(poi.name ?? FacilityKind.fromAPI(poi.category)?.rawValue ?? "Stop").font(.headline)
                        Text("Near \(Int(stop.distance_marker_meters)) m • \(stop.hours_status == "open" ? "Hours matched the planned arrival" : "Hours unknown")").font(.caption)
                        if poi.unavailable { Text("Reported unavailable — choose another stop.").foregroundStyle(.red) }
                        HStack {
                            Button("Walk to stop") { Task { await navigate(to: poi) } }.disabled(busy || poi.unavailable)
                            Button("Report") { report = poi.place }
                        }.buttonStyle(.bordered)
                    }.padding(.vertical, 4)
                }
                ForEach(result.properties.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                Text("© OpenStreetMap contributors • Mapbox walking access • PausePath community").font(.caption2)
            }
        }
        .fullScreenCover(item: $detour, onDismiss: onReturn) { WalkingNavigationView(walk: $0) }
        .sheet(item: $report) { place in StopReportView(place: place, coordinate: place.item.placemark.coordinate) { Task { await refreshStatuses() } } }
        .task(id: result?.properties.break_points.count) {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if scenePhase == .active { await refreshStatuses() }
            }
        }
    }
    private func load() async {
        busy = true; result = nil; latest = [:]; onStopsChanged([]); message = "Checking nearby stops and pedestrian access…"
        defer { busy = false }
        do {
            // Hydrate the small route's bounding area before curation. Large routes
            // still use existing data rather than submitting an unbounded fetch.
            var rect = MKMapRect.null
            for leg in walk.legs { rect = rect.union(leg.polyline.boundingMapRect) }
            let padding = 200 * MKMapPointsPerMeterAtLatitude(walk.start.latitude)
            let region = MKCoordinateRegion(rect.insetBy(dx: -padding, dy: -padding))
            _ = try? await PausePathAPI.search(region)
            try Task.checkCancellation()
            result = try await PausePathAPI.curate(walk, allowUnknown: allowUnknown)
            onStopsChanged(result?.properties.break_points.map(\.poi) ?? [])
            message = "Stops checked just now. Community status refreshes every minute while this screen is open."
        } catch { message = error.localizedDescription }
    }
    private func refreshStatuses() async {
        guard let result else { return }
        do {
            for stop in result.properties.break_points.prefix(50) {
                let data = try await PausePathAPI.request("api/v1/pois/\(stop.id.uuidString)")
                latest[stop.id] = try JSONDecoder().decode(SharedPOI.self, from: data)
            }
            onStopsChanged(result.properties.break_points.map { latest[$0.id] ?? $0.poi })
        } catch { message = "Stop updates unavailable. Last known status is shown; refresh before relying on a stop." }
    }
    private func navigate(to poi: SharedPOI) async {
        guard poi.location.coordinates.count == 2 else { return }
        busy = true; defer { busy = false }
        do {
            let origin = currentLocation.map { Coordinate($0.latitude, $0.longitude) } ?? walk.start
            let leg = try await WalkingDirections.route(from: origin, to: Coordinate(poi.coordinate.latitude, poi.coordinate.longitude), departure: .now)
            onDetour()
            detour = GeneratedWalk(name: poi.name ?? "Break stop", legs: [leg], preferences: walk.preferences)
        } catch { message = "Walking directions to this stop are unavailable. Try another stop." }
    }
}
