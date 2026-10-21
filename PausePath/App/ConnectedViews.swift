import SwiftUI
import MapKit
import AuthenticationServices
import UIKit

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
                    Text("Recently explored public stops can be saved on this phone for seven days. Clear them in Profile’s Saved areas & navigation. Starting a walk can keep location guidance running while locked; Pause and End stop tracking.")
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
                        Text("Your activity recap is available in My Path when you open PausePath.")
                        Button("Allow an 8 PM reminder", systemImage: "bell.badge") {
                            Task {
                                let enabled = await DailyRecapNotifications.enable()
                                var updated = (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile()
                                updated.dailyRecapNotifications = enabled
                                profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                            }
                        }
                    }
                    Text("If enabled, an 8 PM reminder tells you when your walking summary is ready in My Path. It never includes route, location, or Health details. Manage notification access in iOS Settings at any time.").font(.footnote)
                }
            }.pausePathSurface()
        .navigationTitle("Account")
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
    @State private var communities: [WalkingCommunity] = []
    @State private var challenges: [UUID: [WalkingCommunityChallenge]] = [:]
    @State private var showCommunityComposer = false
    @State private var communityComposerStartsWithJoin = false
    @AppStorage("pausepath.pendingCommunityInvite") private var pendingInviteCode = ""
    @State private var challengeSheetTarget: ChallengeTarget?
    @State private var message = ""
    @State private var communityLoadMessage: String?
    @State private var challengeLoadMessages: [UUID: String] = [:]
    @State private var communityRevision = UUID()
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
    @AppStorage("pausepath.weeklyChallengeRewards") private var rewardLedgerData = Data()
    @Environment(\.scenePhase) private var scenePhase
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(PausePathPalette.teal.opacity(0.08)).frame(width: 104, height: 104)
                            Circle().fill(PausePathPalette.lime).frame(width: 76, height: 76)
                            Image(systemName: "person.3.fill").font(.system(size: 29, weight: .semibold)).foregroundStyle(PausePathPalette.ink)
                            Image(systemName: "leaf.fill").font(.caption.bold()).foregroundStyle(PausePathPalette.teal)
                                .padding(9).background(.background, in: Circle()).offset(x: 38, y: 28)
                        }.accessibilityHidden(true)
                        Text("Good paths. Better together.").font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(PausePathPalette.teal)
                        Text("Create a community for your friends, or join one with an invite code.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button {
                            communityComposerStartsWithJoin = false; showCommunityComposer = true
                        } label: {
                            Label("Create a community", systemImage: "plus.circle.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                        Button {
                            communityComposerStartsWithJoin = true; showCommunityComposer = true
                        } label: {
                            Label("Join with a code", systemImage: "person.badge.plus")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.bordered)
                        if !account.isSignedIn {
                            Text("Sign in with Apple in the next step.").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 16) {
                            Label("Your people", systemImage: "person.2")
                            Label("Your pace", systemImage: "leaf")
                        }.font(.caption.weight(.medium)).foregroundStyle(PausePathPalette.teal)
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                }.listRowBackground(PausePathPalette.teal.opacity(0.05))
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
                        }.padding(14)
                            .background(complete ? PausePathPalette.lime.opacity(0.22) : PausePathPalette.teal.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    }.listRowSeparator(.hidden)
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
                } header: { Label("Small steps this week", systemImage: "sparkles") }
                Section("Communities") {
                    if let communityLoadMessage {
                        Label(communityLoadMessage, systemImage: "arrow.clockwise.circle")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Refresh communities") { Task { await refresh() } }.disabled(busy)
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
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Make room for your walking circle", systemImage: "person.2.circle").font(.headline)
                                Text("Create a group above, then share its code with a friend. Your first shared path starts here.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                        ForEach(communities) { community in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Label(community.name, systemImage: "person.2.fill").font(.headline).foregroundStyle(PausePathPalette.teal)
                                    Spacer()
                                    Text("\(community.member_count) members").font(.caption).foregroundStyle(.secondary)
                                }
                                CommunityInviteCard(code: community.invite_code)
                                Text("You appear as \(community.my_display_name)").font(.caption).foregroundStyle(.secondary)
                                if let members = community.members, !members.isEmpty {
                                    Text("Members").font(.caption.weight(.semibold))
                                    Text(members.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                }
                                Text("Community members can see these usernames. They see your activity totals only while progress sharing is on; routes, locations, and Health data stay private.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if let list = challenges[community.id], !list.isEmpty {
                                    ForEach(list) { challenge in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(challenge.name).font(.subheadline.weight(.semibold))
                                            ProgressView(value: min(challenge.my_progress ?? 0, challenge.target), total: challenge.target)
                                            Text("\((challenge.my_progress ?? 0), specifier: "%.1f") / \(challenge.target, specifier: "%.1f") \(unit(challenge.metric))")
                                                .font(.caption).foregroundStyle(.secondary)
                                            if (challenge.my_progress ?? 0) >= challenge.target {
                                                Label("Completed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                            }
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
                                } else if challengeLoadMessages[community.id] == nil {
                                    Text("A fresh start. Add your first shared challenge.").font(.caption).foregroundStyle(.secondary)
                                }
                                if let notice = challengeLoadMessages[community.id] {
                                    Label(notice, systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Create a community task", systemImage: "plus") { challengeSheetTarget = ChallengeTarget(community.id) }
                                    .font(.subheadline)
                            }.padding(.vertical, 12)
                        }
                    }
                }
                Section {
                    Text("Take part at your own pace. A challenge is not a fitness test or medical recommendation; choose a goal that feels appropriate for you.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !message.isEmpty { Section { Text(message).font(.callout); Button("Retry community connection") { Task { await refresh() } }.disabled(busy) } }
            }
            .pausePathSurface()
        .navigationTitle("Community")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 4) { Image(systemName: "star.fill"); Text("\(monthlyPoints)") }
                        .font(.subheadline.weight(.semibold)).accessibilityLabel("\(monthlyPoints) points this month")
                }
            }
            .task { loadWeeklyChallenges(); if !pendingInviteCode.isEmpty { showCommunityComposer = true }; await refresh() }
            .refreshable { loadWeeklyChallenges(); await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { loadWeeklyChallenges(); Task { await refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathWalkRecorded)) { _ in
                updateWeeklyProgress(); Task { await refresh() }
            }
            .onChange(of: account.userID) { _, userID in
                if userID != nil { Task { await refresh() } }
                else { communityRevision = UUID(); communities = []; challenges = [:]; challengeLoadMessages = [:]; communityLoadMessage = nil; message = "" }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathJoinCommunity)) { notification in
                pendingInviteCode = notification.userInfo?["code"] as? String ?? ""
                showCommunityComposer = true
            }
            .onChange(of: pendingInviteCode) { _, code in if !code.isEmpty { showCommunityComposer = true } }
            .onChange(of: preferences) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: profileData) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: shareProgress) { _, enabled in
                Task {
                    if enabled { await refresh() }
                    else {
                        do { try await PausePathAPI.clearChallengeProgress(); await refresh() }
                        catch { message = communityErrorMessage(error) }
                    }
                }
            }
            .sheet(isPresented: $showCommunityComposer, onDismiss: {
                pendingInviteCode = ""
                Task { await refresh() }
            }) {
                CommunityJoinSheet(account: account, onCreate: createCommunity, onJoin: joinCommunity, initialUsername: profile.username ?? "", initialInviteCode: pendingInviteCode, startsWithJoin: communityComposerStartsWithJoin)
            }
            .sheet(item: $challengeSheetTarget) { target in
                ChallengeComposer(onSave: { name, metric, amount in
                    try await createChallenge(communityID: target.id, name: name, metric: metric, target: amount)
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
        for index in weeklyChallenges.indices where weeklyChallenges[index].title == "Walk a distance that fits your route preferences" && !weeklyChallenges[index].pointsAwarded {
            guard weeklyProgress(for: weeklyChallenges[index]) == 0 else { continue }
            weeklyChallenges[index].target = suggestedDistanceTarget
        }
        storeWeeklyChallenges()
    }
    private func refreshWeeklyChallenges() {
        if challengeWeekKey != currentWeekKey { loadWeeklyChallenges() }
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
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return 0 }
        return ChallengeProgressCalculator.total(metric: challenge.kind, walks: walks,
                                                  from: interval.start, until: min(Date(), interval.end))
    }

    private func challengeProgressLabel(_ challenge: WeeklyPersonalChallenge, progress: Double) -> String {
        if challenge.kind == "distance_km" { return String(format: "%.1f / %.1f km", progress, challenge.target) }
        return "\(min(Int(progress), Int(challenge.target))) / \(Int(challenge.target))"
    }
    private func updateWeeklyProgress() {
        guard challengeWeekKey == currentWeekKey else { loadWeeklyChallenges(); return }
        if pointsMonthKey != currentMonthKey { pointsMonthKey = currentMonthKey; monthlyPoints = 0 }
        var ledger = (try? JSONDecoder().decode(ChallengeRewardLedger.self, from: rewardLedgerData)) ?? ChallengeRewardLedger()
        // Preserve awards from decks saved before the reward ledger existed.
        for challenge in weeklyChallenges where challenge.pointsAwarded {
            _ = ledger.claim(challenge.title, week: currentWeekKey)
        }
        for index in weeklyChallenges.indices {
            if weeklyProgress(for: weeklyChallenges[index]) >= weeklyChallenges[index].target {
                if ledger.claim(weeklyChallenges[index].title, week: currentWeekKey) { monthlyPoints += 10 }
                weeklyChallenges[index].pointsAwarded = true
            }
        }
        rewardLedgerData = (try? JSONEncoder().encode(ledger)) ?? rewardLedgerData
        storeWeeklyChallenges()
    }
    private func unit(_ metric: String) -> String {
        switch metric { case "distance_km": "km"; case "minutes": "minutes"; case "new_routes": "routes"; default: "walks" }
    }
    @MainActor private func refresh() async {
        guard account.isSignedIn, !busy else { return }
        let revision = UUID()
        communityRevision = revision
        busy = true
        defer { busy = false }
        do {
            let loaded = try await PausePathAPI.communities()
            guard communityRevision == revision, account.isSignedIn else { return }
            communities = loaded
            communityLoadMessage = nil
            message = ""
        } catch {
            guard communityRevision == revision else { return }
            communityLoadMessage = "We couldn’t refresh your groups. Pull down to try again."
            return
        }
        guard !communities.isEmpty else { return }
        // A secondary request must never erase working communities or their invite codes.
        if let username = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty {
            do { try await PausePathAPI.updateCommunityUsername(username) }
            catch {
                guard communityRevision == revision else { return }
                message = "Your groups are loaded. Your updated username hasn’t synced yet."
            }
        }
        guard communityRevision == revision else { return }
        do {
            if shareProgress { try await PausePathAPI.syncChallengeProgress(walks: walks) }
            else { try await PausePathAPI.clearChallengeProgress() }
            guard communityRevision == revision else { return }
            if message.contains("progress") { message = "" }
        } catch {
            guard communityRevision == revision else { return }
            message = shareProgress
                ? "Your groups are ready. Challenge progress will retry on refresh."
                : "Your groups are ready. Removing shared progress hasn’t finished; refresh to retry."
        }
        for community in communities {
            do {
                let list = try await PausePathAPI.challenges(in: community.id)
                guard communityRevision == revision else { return }
                challenges[community.id] = list
                challengeLoadMessages[community.id] = nil
            } catch {
                guard communityRevision == revision else { return }
                challengeLoadMessages[community.id] = "Tasks haven’t refreshed yet. Your invite code is still ready to share."
            }
        }
    }
    private func saveCommunityUsername(_ username: String) {
        var updated = profile; updated.username = username
        profileData = (try? JSONEncoder().encode(updated)) ?? profileData
    }
    private func createCommunity(name: String, username: String) async throws -> WalkingCommunity {
        let community = try await PausePathAPI.createCommunity(name: name, username: username)
        communityRevision = UUID()
        communityLoadMessage = nil
        saveCommunityUsername(username)
        communities.removeAll { $0.id == community.id }
        communities.insert(community, at: 0)
        message = ""
        return community
    }
    private func joinCommunity(code: String, username: String) async throws -> WalkingCommunity {
        let community = try await PausePathAPI.joinCommunity(code: code, username: username)
        communityRevision = UUID()
        communityLoadMessage = nil
        saveCommunityUsername(username)
        communities.removeAll { $0.id == community.id }
        communities.insert(community, at: 0)
        message = ""
        return community
    }
    private func createChallenge(communityID: UUID, name: String, metric: String, target: Double) async throws {
        try await PausePathAPI.createChallenge(in: communityID, name: name, metric: metric, target: target); message = "Community task created. Everyone can join at their own pace."; await refresh()
    }
}

private struct SegmentedChallengeProgress: View {
    let value: Double
    let total: Double
    private var count: Int { max(1, min(20, Int(total.rounded(.up)))) }
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<count, id: \.self) { index in
                GeometryReader { geometry in
                    let segmentProgress = min(1, max(0, (total > 0 ? value / total : 0) * Double(count) - Double(index)))
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

private struct CommunityJoinSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    let account: PausePathAccount
    let onCreate: (String, String) async throws -> WalkingCommunity
    let onJoin: (String, String) async throws -> WalkingCommunity
    let initialUsername: String
    let initialInviteCode: String
    let startsWithJoin: Bool
    @State private var isJoining = false
    @State private var name = ""
    @State private var code = ""
    @State private var username = ""
    @State private var busy = false
    @State private var submissionError = ""
    @State private var result: WalkingCommunity?

    var body: some View {
        NavigationStack {
            Form {
                if let result {
                    successCard(result)
                } else {
                    Section {
                        Picker("Community action", selection: $isJoining) {
                            Text("Create").tag(false)
                            Text("Join").tag(true)
                        }.pickerStyle(.segmented).disabled(busy)
                    }
                    accountSection
                    Section {
                        TextField("Your community username", text: $username)
                            .textInputAutocapitalization(.words).autocorrectionDisabled().disabled(busy)
                            .accessibilityLabel("Your community username")
                    } header: { Text("Your display name") }
                      footer: { Text("This is the name other members see. Use 1–32 characters.") }
                    if isJoining {
                        Section {
                            TextField("Enter invite code", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().disabled(busy)
                                .font(.body.monospaced()).accessibilityLabel("Community invite code")
                        } header: { Text("Invite code") }
                          footer: { Text("Ask a member for their code. You do not need to create a community first.") }
                    } else {
                        Section {
                            TextField("For example, Weekend Walkers", text: $name)
                                .textInputAutocapitalization(.words).disabled(busy).accessibilityLabel("Community name")
                        } header: { Text("Community name") }
                          footer: { Text("Use 2–60 characters. Your invite code appears after creation.") }
                    }
                    Section {
                        Button { Task { await submit() } } label: {
                            HStack(spacing: 8) {
                                if busy { ProgressView().tint(.white) }
                                Text(busy ? (isJoining ? "Joining…" : "Creating…") : (isJoining ? "Join community" : "Create community"))
                                    .font(.headline)
                            }.frame(maxWidth: .infinity, minHeight: 44)
                        }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink).disabled(!canSubmit || busy)
                        if !submissionError.isEmpty {
                            Label(submissionError, systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } footer: { Text("Progress sharing stays optional. Your routes and locations remain private.") }
                }
            }
            .pausePathSurface()
        .navigationTitle(result == nil ? (isJoining ? "Join a community" : "Create a community") : "You're in!")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear { username = initialUsername; code = initialInviteCode; isJoining = startsWithJoin || !initialInviteCode.isEmpty }
            .onChange(of: isJoining) { _, _ in submissionError = "" }
        }
    }

    @ViewBuilder private var accountSection: some View {
        if !account.isSignedIn {
            Section("Connect your account") {
                Text("Sign in with Apple to create or join. Your entries stay here while you sign in.").font(.callout)
                SignInWithAppleButton(.continue,
                    onRequest: { request in account.prepareAppleSignIn(request) },
                    onCompletion: { result in Task { await account.completeAppleSignIn(result) } })
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 48).disabled(account.busy)
                if account.busy { ProgressView("Signing in…") }
                if !account.message.isEmpty { Text(account.message).font(.caption).foregroundStyle(.secondary) }
            }
        } else if account.sessionState != .ready {
            Section("Account connection") {
                Text(account.sessionStatusText).font(.callout)
                Text(account.message).font(.caption).foregroundStyle(.secondary)
                Button("Retry account connection") { Task { await account.restoreSessionIfNeeded() } }
                    .disabled(account.sessionState == .checking)
            }
        }
    }

    private func successCard(_ community: WalkingCommunity) -> some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 44)).foregroundStyle(PausePathPalette.teal)
                Text(isJoining ? "You joined \(community.name)" : "\(community.name) is ready")
                    .font(.title2.bold()).multilineTextAlignment(.center)
                Text("Share this invite code with someone you want to walk with.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                CommunityInviteCard(code: community.invite_code)
                Text("They can open Community, choose Join with a code, and enter this code with their own username.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
        }
    }

    private var cleanUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanCode: String { code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    private var canSubmit: Bool {
        account.isSignedIn && account.sessionState == .ready && (1...32).contains(cleanUsername.count) &&
        (isJoining ? (4...12).contains(cleanCode.count) : (2...60).contains(cleanName.count))
    }
    @MainActor private func submit() async {
        guard canSubmit, !busy else { return }
        busy = true; submissionError = ""
        defer { busy = false }
        do {
            if isJoining { result = try await onJoin(cleanCode, cleanUsername) }
            else { result = try await onCreate(cleanName, cleanUsername) }
        } catch { submissionError = communityErrorMessage(error) }
    }
}

private struct ChallengeComposer: View {
    let onSave: (String, String, Double) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Walk a little at your pace"
    @State private var metric = "walks"
    @State private var target = 3.0
    @State private var busy = false
    @State private var submissionError = ""
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
                if !submissionError.isEmpty { Text(submissionError).foregroundStyle(.secondary) }
            }.pausePathSurface()
        .navigationTitle("Community task")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") { Task { busy = true; defer { busy = false }; do { try await onSave(name, metric, target); dismiss() } catch { submissionError = communityErrorMessage(error) } } }
                            .disabled(busy || !(2...80).contains(name.trimmingCharacters(in: .whitespacesAndNewlines).count))
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
            }.pausePathSurface()
        .navigationTitle("Community report")
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

private func communityErrorMessage(_ error: Error) -> String {
    if let failure = error as? ServiceFailure {
        switch failure.status {
        case 401, 403: return "Reconnect your account to continue. Your entries are still here."
        case 404:
            if failure.message.localizedCaseInsensitiveContains("invite") {
                return "That invite code didn’t match a community. Check the code and try again."
            }
            return "We couldn’t complete this request. Your entries are still here; please try again."
        case 409: return "That name or request is already in use. Check your communities or try another name."
        case 429: return "A few requests arrived together. Give it a moment, then try again."
        case 500...599: return "We couldn’t confirm the request. Your entries are still here. Check your communities before trying again."
        case 400, 422: return "Check your community name, username and invite code, then try again."
        default: break
        }
    }
    if let network = error as? URLError, network.code == .notConnectedToInternet {
        return "You’re offline. Connect to the internet, then try again."
    }
    return "We couldn’t confirm the request. Your entries are still here; please try again."
}

private struct CommunityInviteCard: View {
    let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("YOUR INVITE CODE", systemImage: "ticket.fill")
                .font(.caption.weight(.bold)).tracking(1).foregroundStyle(PausePathPalette.teal)
            Text(code).font(.system(.title, design: .monospaced).bold())
                .foregroundStyle(PausePathPalette.teal).textSelection(.enabled)
                .lineLimit(1).minimumScaleFactor(0.6)
                .accessibilityLabel("Invite code, \(code)")
            Text("Friends can enter this in Join with a code.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    UIPasteboard.general.string = code; copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 32)
                }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                ShareLink(item: "Join my PausePath community with code \(code)\nPausePath: pausepath://community/join?code=\(code)") {
                    Label("Share", systemImage: "square.and.arrow.up").frame(minHeight: 32)
                }.buttonStyle(.bordered).tint(PausePathPalette.teal)
            }.font(.subheadline.weight(.semibold))
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PausePathPalette.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(PausePathPalette.teal.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .onChange(of: code) { copied = false }
    }
}
