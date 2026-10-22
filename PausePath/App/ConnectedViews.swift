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
    @State private var communitySearch = ""
    @State private var lastCommunityRefresh: Date?
    @State private var refreshAgain = false
    @State private var challenges: [UUID: [WalkingCommunityChallenge]] = [:]
    @State private var showCommunityComposer = false
    @State private var communityComposerStartsWithJoin = false
    @AppStorage("pausepath.pendingCommunityInvite") private var pendingInviteCode = ""
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
    @State private var showWeeklyChallenges = false
    @AppStorage("pausepath.weeklyChallengeRewards") private var rewardLedgerData = Data()
    @Environment(\.scenePhase) private var scenePhase
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !communities.isEmpty { communityOverview } else {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle().fill(PausePathPalette.teal.opacity(0.08)).frame(width: 76, height: 76)
                            Circle().fill(PausePathPalette.lime).frame(width: 60, height: 60)
                            Image(systemName: "person.3.fill").font(.system(size: 29, weight: .semibold)).foregroundStyle(PausePathPalette.ink)
                            Image(systemName: "leaf.fill").font(.caption.bold()).foregroundStyle(PausePathPalette.teal)
                                .padding(9).background(.background, in: Circle()).offset(x: 38, y: 28)
                        }.accessibilityHidden(true)
                        Text("Walk together").font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(PausePathPalette.teal)
                        Text("Create a group or join with a code.")
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

                    }.frame(maxWidth: .infinity).padding(.vertical, 16)
                    }
                }.listRowBackground(PausePathPalette.teal.opacity(0.05))
                Section("Your communities") {
                    if communities.count > 1 {
                        TextField("Find your community", text: $communitySearch).autocorrectionDisabled()
                            .accessibilityLabel("Search your communities")
                    }
                    if let lastCommunityRefresh {
                        HStack {
                            Label("Updated", systemImage: "checkmark.circle").foregroundStyle(PausePathPalette.teal)
                            Text(lastCommunityRefresh, style: .relative).foregroundStyle(.secondary)
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                        }.font(.caption)
                    }
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
                        ForEach(filteredCommunities) { community in
                            NavigationLink {
                                CommunityHubView(community: community)
                            } label: {
                                HStack(spacing: 14) {
                                    TrailEmblem(seed: community.id.uuidString)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(community.name).font(.headline)
                                        Text("\(community.member_count) members · \(challenges[community.id]?.count ?? 0) goals")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 8)
                            }
                        }
                        DisclosureGroup("Progress sharing") {
                            Toggle("Share my goal totals", isOn: $shareProgress)
                            Text("Only totals from this account are shared. Routes, locations and Health data stay private. Turning this off removes your totals from group boards.")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                    }
                }
                Section {
                    DisclosureGroup("Weekly suggestions", isExpanded: $showWeeklyChallenges) {
                    ForEach(weeklyChallenges) { challenge in
                        let progress = weeklyProgress(for: challenge)
                        let complete = progress >= challenge.target
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(challenge.title).font(.headline)
                                Button(role: .destructive) {
                                    weeklyChallenges.removeAll { $0.id == challenge.id }; storeWeeklyChallenges()
                                } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                                    .buttonStyle(.borderless).accessibilityLabel("Remove suggestion: \(challenge.title)")
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
                    if weeklyChallenges.isEmpty { Text("No weekly suggestions. Use Refresh to choose new ones.").font(.caption).foregroundStyle(.secondary) }
                    }
                } header: { Label("Small steps this week", systemImage: "sparkles") }
                if !message.isEmpty { Section { Text(message).font(.callout); Button("Retry community connection") { Task { await refresh() } }.disabled(busy) } }
            }
            .pausePathSurface()
        .navigationTitle("Community")
            .task { if UserDefaults.standard.string(forKey: "pausepath.shareProgressOwner") != account.userID { shareProgress = false }; loadWeeklyChallenges(); if !pendingInviteCode.isEmpty { showCommunityComposer = true }; await refresh() }
            .refreshable { loadWeeklyChallenges(); await refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { loadWeeklyChallenges(); Task { await refresh() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathWalkRecorded)) { _ in
                updateWeeklyProgress(); Task { await refresh() }
            }
            .onChange(of: account.userID) { _, userID in
                communityRevision = UUID(); communities = []; challenges = [:]; challengeLoadMessages = [:]
                communityLoadMessage = nil; message = ""; communitySearch = ""; lastCommunityRefresh = nil
                if userID != nil {
                    if UserDefaults.standard.string(forKey: "pausepath.shareProgressOwner") != userID { shareProgress = false }
                    Task { await refresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathJoinCommunity)) { notification in
                pendingInviteCode = notification.userInfo?["code"] as? String ?? ""
                showCommunityComposer = true
            }
            .onChange(of: pendingInviteCode) { _, code in if !code.isEmpty { showCommunityComposer = true } }
            .onChange(of: preferences) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: profileData) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: shareProgress) { _, enabled in
                if enabled { UserDefaults.standard.set(account.userID, forKey: "pausepath.shareProgressOwner") }
                Task { await refresh() }
            }
            .sheet(isPresented: $showCommunityComposer, onDismiss: {
                pendingInviteCode = ""
                Task { await refresh() }
            }) {
                CommunityJoinSheet(account: account, onCreate: createCommunity, onJoin: joinCommunity, initialUsername: profile.username ?? "", initialInviteCode: pendingInviteCode, startsWithJoin: communityComposerStartsWithJoin)
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
           let decoded = try? JSONDecoder().decode([WeeklyPersonalChallenge].self, from: weeklyChallengeData), decoded.count <= 2 {
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
    private var filteredCommunities: [WalkingCommunity] {
        let query = communitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? communities : communities.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var communityOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            AdventureHeader(eyebrow: "THE PATH IS BETTER TOGETHER", title: "Find your trail crew.", subtitle: "Familiar faces. New places. Your next outing starts here.")
            Text("\(communities.count) \(communities.count == 1 ? "community" : "communities") · \(challenges.values.flatMap { $0 }.count) shared goals")
                .font(.subheadline).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { communityActions }
                VStack(alignment: .leading) { communityActions }
            }
            if !communitySearch.isEmpty && filteredCommunities.isEmpty {
                Text("No groups match that name.").font(.caption).foregroundStyle(.secondary)
                Button("Clear search") { communitySearch = "" }.font(.caption)
            }
        }.padding(.vertical, 10)
    }
    @ViewBuilder private var communityActions: some View {
        Button { communityComposerStartsWithJoin = false; showCommunityComposer = true } label: {
            Label("Create", systemImage: "plus.circle.fill").frame(minHeight: 44)
        }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
        Button { communityComposerStartsWithJoin = true; showCommunityComposer = true } label: {
            Label("Join with a code", systemImage: "person.badge.plus").frame(minHeight: 44)
        }.buttonStyle(.bordered)
    }
    @MainActor private func refresh() async {
        guard account.isSignedIn else { return }
        if busy { refreshAgain = true; return }
        let revision = UUID(); communityRevision = revision; busy = true
        defer {
            busy = false
            if refreshAgain { refreshAgain = false; Task { await refresh() } }
        }
        let loaded: [WalkingCommunity]
        do {
            loaded = try await PausePathAPI.communities()
            guard communityRevision == revision, account.isSignedIn else { return }
            communities = loaded
            let ids = Set(loaded.map(\.id))
            challenges = challenges.filter { ids.contains($0.key) }
            challengeLoadMessages = challengeLoadMessages.filter { ids.contains($0.key) }
            communityLoadMessage = nil; message = ""; lastCommunityRefresh = .now
        } catch {
            guard communityRevision == revision else { return }
            communityLoadMessage = communityErrorMessage(error)
            return
        }
        guard !loaded.isEmpty else { return }
        // Only list calls run together. Mutations below remain ordered and optional.
        var loadedTasks: [UUID: [WalkingCommunityChallenge]] = [:]
        await withTaskGroup(of: (UUID, Result<[WalkingCommunityChallenge], Error>).self) { group in
            var remaining = loaded.dropFirst(4).makeIterator()
            for community in loaded.prefix(4) {
                group.addTask {
                    do { return (community.id, .success(try await PausePathAPI.challenges(in: community.id))) }
                    catch { return (community.id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                guard communityRevision == revision, account.isSignedIn else { group.cancelAll(); return }
                switch result {
                case .success(let list): loadedTasks[id] = list; challenges[id] = list; challengeLoadMessages[id] = nil
                case .failure: challengeLoadMessages[id] = "Shared goals could not refresh. Pull down to retry; your group and invite code remain available."
                }
                if let community = remaining.next() {
                    group.addTask {
                        do { return (community.id, .success(try await PausePathAPI.challenges(in: community.id))) }
                        catch { return (community.id, .failure(error)) }
                    }
                }
            }
        }
        guard communityRevision == revision else { return }
        do {
            let changed: Set<UUID>
            if shareProgress { changed = try await PausePathAPI.syncChallengeProgress(walks: walks, groups: loaded, tasks: loadedTasks) }
            else { changed = try await PausePathAPI.clearChallengeProgress(groups: loaded, tasks: loadedTasks) }
            for id in changed {
                let list = try await PausePathAPI.challenges(in: id)
                guard communityRevision == revision else { return }; challenges[id] = list
            }
        } catch {
            guard communityRevision == revision else { return }
            message = shareProgress ? "Your groups and goals are loaded. Progress syncing will retry on refresh." : "Removing shared totals hasn’t finished. Pull down to retry."
        }
    }
    private func saveCommunityUsername(_ username: String) {
        var updated = profile; updated.username = username
        profileData = (try? JSONEncoder().encode(updated)) ?? profileData
    }
    private func createCommunity(name: String, username: String, requestID: UUID) async throws -> WalkingCommunity {
        let community = try await PausePathAPI.createCommunity(name: name, username: username, requestID: requestID)
        communityRevision = UUID()
        communityLoadMessage = nil
        saveCommunityUsername(username)
        communities.removeAll { $0.id == community.id }
        communities.insert(community, at: 0)
        communitySearch = ""; lastCommunityRefresh = .now
        message = ""
        return community
    }
    private func joinCommunity(code: String, username: String, requestID: UUID) async throws -> WalkingCommunity {
        let community = try await PausePathAPI.joinCommunity(code: code, username: username, requestID: requestID)
        communityRevision = UUID()
        communityLoadMessage = nil
        saveCommunityUsername(username)
        communities.removeAll { $0.id == community.id }
        communities.insert(community, at: 0)
        communitySearch = ""; lastCommunityRefresh = .now
        message = ""
        return community
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
    let onCreate: (String, String, UUID) async throws -> WalkingCommunity
    let onJoin: (String, String, UUID) async throws -> WalkingCommunity
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
    @State private var draft = CommunitySubmissionDraft()
    @State private var didRestoreDraft = false
    @AppStorage("pausepath.communitySubmissionDraft.v1") private var savedDraft = Data()

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
                            TextField("Paste a code or PausePath invite link", text: $code)
                                .textInputAutocapitalization(.characters).autocorrectionDisabled().disabled(busy)
                                .font(.body.monospaced()).accessibilityLabel("Community invite code")
                        } header: { Text("Invite code") }
                          footer: { Text("Paste a member’s code or PausePath invite link. Spaces and hyphens are ignored.") }
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
                            Text("Your draft is saved on this device. Retrying unchanged details uses the same request.").font(.caption).foregroundStyle(.secondary)
                        }
                    } footer: { Text("Progress sharing stays optional. Your routes and locations remain private.") }
                }
            }
            .pausePathSurface()
        .navigationTitle(result == nil ? (isJoining ? "Join a community" : "Create a community") : "You're in!")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .onAppear {
                guard !didRestoreDraft else { return }; didRestoreDraft = true
                if let restored = try? JSONDecoder().decode(CommunitySubmissionDraft.self, from: savedDraft), restored.ownerID == (account.userID ?? "signed-out") {
                    draft = restored; username = restored.username; name = restored.name; code = restored.code; isJoining = restored.joining
                } else { username = initialUsername; code = initialInviteCode; isJoining = startsWithJoin || !initialInviteCode.isEmpty }
                if !initialInviteCode.isEmpty { code = initialInviteCode; isJoining = true }
                storeDraft()
            }
            .onChange(of: [name, code, username, String(isJoining), account.userID ?? "signed-out"]) { _, _ in storeDraft() }
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
    private var cleanCode: String { CommunityInvite.normalizedCode(code) }
    private var canSubmit: Bool {
        account.isSignedIn && account.sessionState != .checking && (1...32).contains(cleanUsername.count) &&
        (isJoining ? CommunityInvite.isValid(cleanCode) : (2...60).contains(cleanName.count))
    }
    private func storeDraft() {
        guard result == nil else { return }
        draft.prepare(ownerID: account.userID ?? "signed-out", joining: isJoining, name: name, code: code, username: username)
        savedDraft = (try? JSONEncoder().encode(draft)) ?? savedDraft
    }
    @MainActor private func submit() async {
        guard canSubmit, !busy else { return }
        busy = true; submissionError = ""
        defer { busy = false }
        do {
            storeDraft()
            if isJoining { result = try await onJoin(cleanCode, cleanUsername, draft.requestID) }
            else { result = try await onCreate(cleanName, cleanUsername, draft.requestID) }
            savedDraft = Data()
        } catch { submissionError = communityErrorMessage(error) }
    }
}

private struct ChallengeComposer: View {
    let scope: String
    var existing: WalkingCommunityChallenge? = nil
    let onSave: (String, String, Double, Bool, UUID) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Walk a little at your pace"
    @State private var metric = "walks"
    @State private var target = 3.0
    @State private var shared = false
    @State private var busy = false
    @State private var submissionError = ""
    @State private var draft = GoalSubmissionDraft()
    private var draftKey: String { "pausepath.goalDraft." + (PausePathAccount.shared.userID ?? "signed-out") + "." + scope }
    private var locksMeasure: Bool { existing.map { !$0.leaderboard.isEmpty || $0.my_progress_shared == true } ?? false }
    private let metrics = ["walks", "distance_km", "minutes", "new_routes"]
    var body: some View {
        NavigationStack {
            Form {
                if existing == nil { Section("Start with an idea") {
                    Button("One walk together", systemImage: "figure.walk") { name = "One walk at your own pace"; metric = "walks"; target = 1 }
                    Button("Explore somewhere new", systemImage: "map") { name = "Try a new route"; metric = "new_routes"; target = 1 }
                    Text("Choose or customize a goal. Everyone can take part at their own pace.").font(.caption).foregroundStyle(.secondary)
                }
                }
                Section("Make it yours") {
                    TextField("Goal name", text: $name)
                    Toggle("Work toward one shared goal", isOn: $shared).disabled(locksMeasure)
                    Picker("Measure progress by", selection: $metric) {
                        ForEach(metrics, id: \.self) { value in Text(metricLabel(value)).tag(value) }
                    }
                    .disabled(locksMeasure)
                    if locksMeasure { Text("This goal already has shared progress. Its measure and group mode stay the same.").font(.caption).foregroundStyle(.secondary) }
                    Stepper("Goal: \(target, specifier: "%.0f") \(unit)", value: $target, in: 1...10000, step: 1)
                }
                Text("Progress sharing is optional. This task appears to members of the community.")
                    .font(.footnote).foregroundStyle(.secondary)
                if !submissionError.isEmpty { Text(submissionError).foregroundStyle(.secondary) }
            }.pausePathSurface()
        .navigationTitle(existing == nil ? "New goal" : "Edit goal")
                .onAppear {
                    if let data = UserDefaults.standard.data(forKey: draftKey), let saved = try? JSONDecoder().decode(GoalSubmissionDraft.self, from: data), saved.ownerID == PausePathAccount.shared.userID {
                        draft = saved; name = saved.name; metric = saved.metric; target = saved.target; shared = saved.shared
                    } else if let existing {
                        name = existing.name; metric = existing.metric; target = existing.target; shared = existing.shared_goal == true
                    }
                }
                .onChange(of: PausePathAccount.shared.userID) { _, _ in dismiss() }
                .interactiveDismissDisabled(busy)
                .disabled(busy)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(existing == nil ? "Create" : "Save") { Task {
                            guard !busy, let owner = PausePathAccount.shared.userID else { return }
                            busy = true; defer { busy = false }
                            draft.prepare(ownerID: owner, scope: scope, name: name, metric: metric, target: target, shared: shared)
                            UserDefaults.standard.set(try? JSONEncoder().encode(draft), forKey: draftKey)
                            do {
                                try await onSave(name, metric, target, shared, draft.requestID)
                                UserDefaults.standard.removeObject(forKey: draftKey); dismiss()
                            } catch { submissionError = communityErrorMessage(error) }
                        } }
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
        case 401: return "Reconnect your account to continue. Your entries are still here."
        case 403: return "This action needs community membership. Refresh your groups and try again."
        case 404:
            if failure.message.localizedCaseInsensitiveContains("invite") {
                return "That invite code didn’t match a community. Check the code and try again."
            }
            return "We couldn’t complete this request. Your entries are still here; please try again."
        case 409: return "This saved request changed. Review your entries and submit again."
        case 429: return "A few requests arrived together. Give it a moment, then try again."
        case 500...599: return "The community service is temporarily unavailable. Your entries are still here; please try again shortly."
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

private struct CommunityWalkPlan: Decodable, Identifiable {
    let id: UUID
    let title: String
    let meeting_point: String
    let route_description: String
    let starts_at: String
    let cancelled: Bool
    let attendees: Int
    let attending: Bool
    let can_manage: Bool
}
private struct CommunityPost: Decodable, Identifiable {
    let id: UUID
    let body: String
    let created_at: String
    let display_name: String
    let cheers: Int
    let cheered: Bool
    let can_delete: Bool
}
private struct CommunityMember: Decodable, Identifiable {
    let user_id: String
    let display_name: String
    var id: String { user_id }
}
private struct CommunityWalkList: Decodable { let walks: [CommunityWalkPlan] }
private struct CommunityPostList: Decodable { let posts: [CommunityPost] }
private struct CommunityMemberList: Decodable { let members: [CommunityMember] }
private struct CommunityPendingAction: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    var body: [String: Any] = [:]
    var closes = false
}

private struct CommunityHubView: View {
    let community: WalkingCommunity
    @Environment(\.dismiss) private var dismiss
    @State private var hubSection = "Walks"
    @State private var showingInvite = false
    @State private var composingPost = false
    @State private var showGoalComposer = false
    @State private var editingGoal: WalkingCommunityChallenge?
    @State private var showArchivedGoals = false
    @State private var displayName = ""
    @State private var loadedSections = Set<String>()
    @State private var loadingSections = Set<String>()
    private var loading: Bool { loadingSections.contains(hubSection) }
    @State private var plans: [CommunityWalkPlan] = []
    @State private var posts: [CommunityPost] = []
    @State private var members: [CommunityMember] = []
    @State private var tasks: [WalkingCommunityChallenge] = []
    @State private var busy = false
    @State private var message = ""
    @State private var newName = ""
    @State private var postText = ""
    @State private var postRequest = UUID()
    @State private var showWalkComposer = false
    @State private var pending: CommunityPendingAction?
    private var base: String { "api/v1/communities/" + community.id.uuidString }
    var body: some View {
        Form {
            if hubSection == "Walks" { walkSection }
            else if hubSection == "Goals" { taskSection }
            else if hubSection == "Posts" { feedSection }
            else { managementSection }
            if !message.isEmpty { Section { Text(message); Button("Retry") { Task { await load(force: true) } }.disabled(loading || busy) } }
            if loading { ProgressView("Refreshing your community…") }
        }.id(hubSection).pausePathSurface().navigationTitle(displayName.isEmpty ? community.name : displayName).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                PathSectionPicker(titles: ["Walks", "Goals", "Posts", "Settings"], selection: $hubSection)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button { showingInvite = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Invite someone")
            } }
            .sheet(isPresented: $showingInvite) {
                NavigationStack {
                    ScrollView { CommunityInviteCard(code: community.invite_code).padding(20) }
                        .pausePathSurface().navigationTitle("Invite someone").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingInvite = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .disabled(busy || loading)
            .task { displayName = community.name; newName = community.name }
            .task(id: hubSection) { await load() }
            .onChange(of: PausePathAccount.shared.userID) { _, _ in
                plans = []; posts = []; members = []; tasks = []; postText = ""; dismiss()
            }
            .refreshable { await load(force: true) }
            .onDisappear { NotificationCenter.default.post(name: .pausePathWalkRecorded, object: nil) }
            .sheet(isPresented: $showGoalComposer, onDismiss: { Task { await load(force: true) } }) {
                ChallengeComposer(scope: community.id.uuidString, onSave: { name, metric, amount, shared, requestID in
                    try await PausePathAPI.createChallenge(in: community.id, name: name, metric: metric, target: amount, shared: shared, requestID: requestID)
                })
            }
            .sheet(item: $editingGoal, onDismiss: { Task { await load(force: true) } }) { goal in
                ChallengeComposer(scope: community.id.uuidString + "." + goal.id.uuidString, existing: goal, onSave: { name, metric, amount, shared, _ in
                    _ = try await PausePathAPI.request(base + "/challenges/" + goal.id.uuidString + "/edit", body: ["name": name, "metric": metric, "target": amount, "shared_goal": shared], requiresAccount: true)
                })
            }
            .sheet(isPresented: $showWalkComposer, onDismiss: { Task { await load(force: true) } }) {
                GroupWalkComposer(group: community.id)
            }
            .alert(pending?.title ?? "Confirm change", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                if let action = pending {
                    Button("Confirm", role: .destructive) { Task { await perform(action.path, body: action.body, closes: action.closes) } }
                }
                Button("Cancel", role: .cancel) { pending = nil }
            } message: { Text("This changes the community for its members.") }
    }
    private var walkSection: some View {
        Section("Walk together") {
            Button { showWalkComposer = true } label: {
                Label("Plan a group walk", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
            ForEach(plans) { plan in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 14) {
                        TrailDateBadge(rawDate: plan.starts_at)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(plan.title).font(.system(.headline, design: .rounded))
                            Text(Self.dateLabel(plan.starts_at)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Label(plan.meeting_point, systemImage: "mappin.and.ellipse")
                    Text(plan.route_description).font(.callout).foregroundStyle(.secondary)
                    if plan.cancelled { Label("Cancelled", systemImage: "xmark.circle") }
                    else {
                        Text("\(plan.attendees) going").font(.caption)
                        Button(plan.attending ? "Cancel my RSVP" : "I'm going", systemImage: plan.attending ? "checkmark.circle.fill" : "person.badge.plus") {
                            Task { await perform("walks/\(plan.id)/rsvp", body: ["attending": !plan.attending]) }
                        }.buttonStyle(.bordered)
                        if plan.can_manage {
                            Button("Cancel group walk", role: .destructive) { pending = CommunityPendingAction(title: "Cancel this walk?", path: "walks/\(plan.id)/cancel") }
                        }
                    }
                }.padding(.vertical, 8)
            }
            if plans.isEmpty && !loading {
                AdventureHeader(eyebrow: "AN OPEN TRAIL", title: "Your next adventure starts here.", subtitle: "Pick a meeting point, gather your crew, and make a little time outdoors.", symbol: "sun.horizon.fill")
            }
        }
    }
    private var feedSection: some View {
        Section("Small wins") {
            Text("Visible to this group. No route or Health data is attached.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Share a small win", isExpanded: $composingPost) {
            TextField("A small win from your path…", text: $postText, axis: .vertical).lineLimit(2...5)
                .onChange(of: postText) { _, _ in postRequest = UUID() }
            Text("\(postText.count)/280").font(.caption).foregroundStyle(.secondary)
            Button("Post to community", systemImage: "paperplane") {
                Task {
                    if await perform("posts", body: ["body": postText, "request_id": postRequest.uuidString]) {
                        postText = ""; postRequest = UUID(); composingPost = false
                    }
                }
            }.disabled(postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || postText.count > 280)
            }
            ForEach(posts) { post in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(post.display_name).font(.headline); Spacer(); Text(Self.dateLabel(post.created_at)).font(.caption2).foregroundStyle(.secondary) }
                    Text(post.body)
                    HStack {
                        Button("\(post.cheers) cheers", systemImage: post.cheered ? "hands.clap.fill" : "hands.clap") {
                            Task { await perform("posts/\(post.id)/cheer", body: ["cheered": !post.cheered]) }
                        }.buttonStyle(.bordered)
                        Spacer()
                        if post.can_delete {
                            Button("Delete", role: .destructive) { pending = CommunityPendingAction(title: "Delete this post?", path: "posts/\(post.id)/delete") }
                        }
                    }
                }.padding(.vertical, 8)
            }
            if posts.isEmpty && !loading { Text("No posts yet. An encouraging word can be the first.").foregroundStyle(.secondary) }
        }
    }
    private var taskSection: some View {
        Section("Goals") {
            Button("Add a goal", systemImage: "plus.circle.fill") { showGoalComposer = true }
            if tasks.contains(where: { $0.archived_at != nil }) { Toggle("Show archived goals", isOn: $showArchivedGoals) }
            ForEach(tasks.filter { showArchivedGoals || $0.archived_at == nil }) { goal in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(goal.name).font(.headline)
                        Spacer()
                        if goal.can_delete == true {
                            Menu {
                                if goal.archived_at == nil {
                                    Button("Edit goal", systemImage: "pencil") { editingGoal = goal }
                                }
                                Button(goal.archived_at == nil ? "Archive goal" : "Restore goal", systemImage: "archivebox") {
                                    Task { await perform("challenges/\(goal.id)/archive", body: ["archived": goal.archived_at == nil]) }
                                }
                            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Edit or archive \(goal.name)")
                            Button(role: .destructive) {
                                pending = CommunityPendingAction(title: "Delete this goal and its progress?", path: "challenges/\(goal.id)/delete")
                            } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("Delete \(goal.name)")
                        }
                    }
                    if goal.archived_at != nil { Label("Archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                    let progress = goal.shared_goal == true ? (goal.group_progress ?? 0) : (goal.my_progress ?? 0)
                    ProgressView(value: min(progress, goal.target), total: goal.target).tint(PausePathPalette.teal)
                    Text("\(progress, specifier: "%.1f") / \(goal.target, specifier: "%.0f") \(goal.metric == "distance_km" ? "km" : goal.metric.replacingOccurrences(of: "_", with: " "))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if !goal.leaderboard.isEmpty {
                        DisclosureGroup("Progress board") {
                            ForEach(Array(goal.leaderboard.enumerated()), id: \.offset) { _, member in
                                HStack { Text(member.name); Spacer(); Text("\(member.amount, specifier: "%.1f")") }.font(.caption)
                            }
                        }.font(.subheadline)
                    }
                }.padding(.vertical, 6)
            }
            if tasks.isEmpty && !loading { Text("No goals yet.").foregroundStyle(.secondary) }
        }
    }
    private var managementSection: some View {
        Section("Community settings") {
            if community.is_owner == true {
                TextField("Community name", text: $newName)
                Button("Save name") { Task { await perform("rename", body: ["name": newName]) } }
                    .disabled(!(2...60).contains(newName.trimmingCharacters(in: .whitespacesAndNewlines).count))
                ForEach(members.filter { $0.user_id != PausePathAccount.shared.userID }) { member in
                    Menu(member.display_name) {
                        Button("Transfer ownership") { pending = CommunityPendingAction(title: "Make \(member.display_name) the owner?", path: "transfer", body: ["user_id": member.id], closes: true) }
                        Button("Remove member", role: .destructive) { pending = CommunityPendingAction(title: "Remove \(member.display_name)?", path: "members/remove", body: ["user_id": member.id]) }
                    }
                }
                Text("Transfer ownership to a member before leaving, or delete the group.").font(.caption).foregroundStyle(.secondary)
                Button("Delete community", role: .destructive) { pending = CommunityPendingAction(title: "Delete this community and all group content?", path: "delete", closes: true) }
            } else {
                Button("Leave community", role: .destructive) { pending = CommunityPendingAction(title: "Leave this community? Your posts, RSVPs, and shared totals will be removed.", path: "leave", closes: true) }
            }
        }
    }
    @MainActor private func load(force: Bool = false) async {
        let section = hubSection
        guard !loadingSections.contains(section), force || !loadedSections.contains(section), let owner = PausePathAccount.shared.userID else { return }
        loadingSections.insert(section)
        defer { loadingSections.remove(section) }
        message = ""
        do {
            switch section {
            case "Walks":
                let value = try JSONDecoder().decode(CommunityWalkList.self, from: await PausePathAPI.request(base + "/walks", requiresAccount: true)).walks
                try Task.checkCancellation()
                guard PausePathAccount.shared.userID == owner else { return }; plans = value
            case "Posts":
                let value = try JSONDecoder().decode(CommunityPostList.self, from: await PausePathAPI.request(base + "/posts", requiresAccount: true)).posts
                try Task.checkCancellation()
                guard PausePathAccount.shared.userID == owner else { return }; posts = value
            case "Goals":
                let value = try await PausePathAPI.challenges(in: community.id)
                try Task.checkCancellation()
                guard PausePathAccount.shared.userID == owner else { return }; tasks = value
            default:
                if community.is_owner == true {
                    let value = try JSONDecoder().decode(CommunityMemberList.self, from: await PausePathAPI.request(base + "/members", requiresAccount: true)).members
                    try Task.checkCancellation()
                guard PausePathAccount.shared.userID == owner else { return }; members = value
                }
            }
            try Task.checkCancellation()
            loadedSections.insert(section)
        } catch {
            if !Task.isCancelled, PausePathAccount.shared.userID == owner { message = "\(section) could not refresh. Pull down to retry." }
        }
    }
    @discardableResult @MainActor private func perform(_ path: String, body: [String: Any] = [:], closes: Bool = false) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            _ = try await PausePathAPI.request(base + "/" + path, body: body, requiresAccount: true)
            if closes { dismiss() } else {
                if path == "rename" { displayName = newName.trimmingCharacters(in: .whitespacesAndNewlines) }
                await load(force: true)
            }
            return true
        } catch { message = communityErrorMessage(error); return false }
    }
    static func dateLabel(_ raw: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable"
    }
}

private struct GroupWalkComposer: View {
    let group: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = "A walk together"
    @State private var meeting = ""
    @State private var route = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("The plan") {
                    TextField("Walk name", text: $title)
                    TextField("Meeting point or address", text: $meeting)
                    TextField("Route and planned breaks", text: $route, axis: .vertical).lineLimit(3...6)
                    DatePicker("Start", selection: $date, in: Date()...)
                }
                Text("These details are shared with your community. Describe a meeting point you are comfortable sharing. Route descriptions are plans, not turn-by-turn navigation.").font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message) }
            }.pausePathSurface().navigationTitle("Plan a group walk")
                .onChange(of: [title, meeting, route, date.ISO8601Format()]) { _, _ in requestID = UUID() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Saving…" : "Schedule") { Task { await save() } }
                            .disabled(busy || !(2...80).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).count) || meeting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || meeting.count > 160 || route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || route.count > 500)
                    }
                }.disabled(busy).interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func save() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            _ = try await PausePathAPI.request("api/v1/communities/\(group)/walks", body: ["title": title, "meeting_point": meeting, "route_description": route, "starts_at": ISO8601DateFormatter().string(from: date), "request_id": requestID.uuidString], requiresAccount: true)
            dismiss()
        } catch { message = communityErrorMessage(error) }
    }
}

private struct TrailDateBadge: View {
    let rawDate: String
    private var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: rawDate) ?? ISO8601DateFormatter().date(from: rawDate)
    }
    var body: some View {
        VStack(spacing: 3) {
            if let date {
                Text(date.formatted(.dateTime.month(.abbreviated)).uppercased()).font(.caption2.bold()).tracking(1)
                Text(date.formatted(.dateTime.day())).font(.system(.title2, design: .rounded).bold())
            } else { Image(systemName: "calendar").font(.title2) }
        }.foregroundStyle(PausePathPalette.ink).padding(10).frame(minWidth: 58)
            .background(Color(red: 0.88, green: 0.84, blue: 0.70), in: RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .top) { Capsule().fill(PausePathPalette.teal).frame(width: 24, height: 3).padding(.top, 4) }
            .accessibilityHidden(true)
    }
}
