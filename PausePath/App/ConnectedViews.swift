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

private struct CommunityComposerRoute: Identifiable {
    let id = UUID()
    let joining: Bool
    let inviteCode: String
}

struct CommunityChallengesView: View {
    let preferences: RoutePreferences
    @State private var account = PausePathAccount.shared
    @State private var social = SocialActivityStore.shared
    @State private var communities: [WalkingCommunity] = []
    @State private var feed: [CommunityFeedItem] = []
    @State private var feedLoading = false
    @State private var feedLoadToken = UUID()
    @State private var feedMessage: String?
    @State private var lastFeedRefresh: Date?
    @State private var reactingPostIDs = Set<UUID>()
    @State private var showingPostComposer = false
    @State private var communitySearch = ""
    @State private var lastCommunityRefresh: Date?
    @State private var refreshAgain = false
    @State private var communityComposerRoute: CommunityComposerRoute?
    @AppStorage("pausepath.pendingCommunityInvite") private var pendingInviteCode = ""
    @State private var message = ""
    @State private var membershipConfirmation: String?
    @State private var communityLoadMessage: String?
    @State private var communityRevision = UUID()
    @State private var busy = false
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.shareChallengeProgress") private var shareProgress = false
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    groupsSection
                    if let membershipConfirmation {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                            Text(membershipConfirmation).font(.subheadline.weight(.semibold))
                            Spacer()
                            Button { self.membershipConfirmation = nil } label: {
                                Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                            }.accessibilityLabel("Dismiss confirmation")
                        }
                        .foregroundStyle(PausePathPalette.teal)
                        .padding(.leading, 16)
                        .background(PausePathPalette.lime.opacity(0.17), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if account.isSignedIn && !communities.isEmpty {
                        sharePrompt
                    }
                    socialShortcuts
                    if communities.isEmpty && (!account.isSignedIn || (communityLoadMessage == nil && !busy)) {
                        communityPossibilities
                    }
                    if account.isSignedIn && !communities.isEmpty {
                        feedSection
                    }
                    if account.isSignedIn {
                        if !upcomingGroups.isEmpty { upcomingSection }
                        if !social.notifications.isEmpty { activitySection }
                    }
                    if account.isSignedIn && !communities.isEmpty {
                        sharingPreferences
                    }
                    if !message.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(message, systemImage: "exclamationmark.circle")
                            Button("Refresh groups") { Task { await refresh(force: true) } }.disabled(busy)
                        }
                        .font(.callout)
                        .padding(16)
                        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 32)
            }
            .pausePathSurface()
            .navigationTitle("Community")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Create group", systemImage: "plus.circle") {
                            communityComposerRoute = CommunityComposerRoute(joining: false, inviteCode: "")
                        }
                        Button("Join by code", systemImage: "person.badge.plus") {
                            communityComposerRoute = CommunityComposerRoute(joining: true, inviteCode: "")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(PausePathPalette.teal)
                            .frame(width: 44, height: 44)
                            .background {
                                Circle().fill(PausePathPalette.lime)
                                    .frame(width: 36, height: 36)
                            }
                    }
                    .accessibilityLabel("Add a group")
                    .accessibilityHint("Create a group or join with an invite code")
                }
            }
            .task {
                if UserDefaults.standard.string(forKey: "pausepath.shareProgressOwner") != account.userID { shareProgress = false }
                if !pendingInviteCode.isEmpty { communityComposerRoute = CommunityComposerRoute(joining: true, inviteCode: pendingInviteCode) }
                Task { await social.refresh() }
                await refresh()
            }
            .refreshable {
                async let groups: Void = refresh(force: true)
                async let activity: Void = social.refresh()
                _ = await (groups, activity)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await social.refresh() }
                    Task { await refresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathWalkRecorded)) { _ in
                Task { await refresh(force: true) }
            }
            .onChange(of: account.userID) { _, userID in
                communityRevision = UUID(); communities = []
                feedLoadToken = UUID(); feed = []; feedMessage = nil; feedLoading = false; lastFeedRefresh = nil
                communityLoadMessage = nil; message = ""; membershipConfirmation = nil; communitySearch = ""; lastCommunityRefresh = nil
                if userID != nil {
                    if UserDefaults.standard.string(forKey: "pausepath.shareProgressOwner") != userID { shareProgress = false }
                    Task { await refresh(force: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathCommunityMembershipChanged)) { _ in Task { await refresh(force: true) } }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathJoinCommunity)) { notification in
                pendingInviteCode = notification.userInfo?["code"] as? String ?? ""
                if !pendingInviteCode.isEmpty { communityComposerRoute = CommunityComposerRoute(joining: true, inviteCode: pendingInviteCode) }
            }
            .onChange(of: pendingInviteCode) { _, code in
                if !code.isEmpty && communityComposerRoute?.inviteCode != code {
                    communityComposerRoute = CommunityComposerRoute(joining: true, inviteCode: code)
                }
            }
            .onChange(of: shareProgress) { _, enabled in
                if !enabled, let owner = account.userID { UserDefaults.standard.set(true, forKey: "pausepath.pendingProgressRemoval." + owner) }
                if enabled { UserDefaults.standard.set(account.userID, forKey: "pausepath.shareProgressOwner") }
                Task { await refresh(force: true) }
            }
            .sheet(item: $communityComposerRoute, onDismiss: {
                pendingInviteCode = ""
                Task { await refresh(force: true) }
            }) { route in
                CommunityJoinSheet(account: account, onCreate: createCommunity, onJoin: joinCommunity, initialUsername: profile.username ?? "", initialInviteCode: route.inviteCode, startsWithJoin: route.joining)
            }
            .sheet(isPresented: $showingPostComposer, onDismiss: {
                guard let owner = account.userID else { return }
                Task { await loadFeed(groups: communities, owner: owner, revision: communityRevision) }
            }) {
                CommunityQuickPostSheet(communities: communities)
            }

        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your groups").font(.title2.bold()).foregroundStyle(PausePathPalette.teal)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                else if let lastCommunityRefresh {
                    Text("Updated \(lastCommunityRefresh, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !account.isSignedIn {
                emptyGroupsCard(signedOut: true)
            } else {
                if let communityLoadMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(communityLoadMessage, systemImage: "arrow.clockwise.circle")
                        Button("Retry groups") { Task { await refresh(force: true) } }.fontWeight(.semibold)
                    }
                    .font(.callout).padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                } else if busy && lastCommunityRefresh == nil {
                    ProgressView("Loading groups…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else if communities.isEmpty {
                    emptyGroupsCard(signedOut: false)
                } else {
                    if communities.count > 4 || !communitySearch.isEmpty {
                        TextField("Search your groups", text: $communitySearch)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 15).padding(.vertical, 12)
                            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 15))
                    }
                    if filteredCommunities.isEmpty {
                        Button("No groups match. Clear search") { communitySearch = "" }
                            .font(.subheadline).frame(minHeight: 44)
                    } else if typeSize.isAccessibilitySize {
                        ForEach(filteredCommunities) { community in groupCard(community).frame(maxWidth: .infinity) }
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(filteredCommunities) { community in
                                    groupCard(community).frame(width: 270)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .contentMargins(.trailing, 18)
                    }
                }
            }
        }
    }

    private func emptyGroupsCard(signedOut: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            communityWelcomeArt
            VStack(alignment: .leading, spacing: 5) {
                Text(signedOut ? "Walk better together" : "Find your walking circle")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(PausePathPalette.teal)
                Text(signedOut
                     ? "Sign in with Apple, then join a group or start one with people you know."
                     : "Have an invite? Join your group. Or start a new one and bring friends along.")
                    .font(.subheadline)
                    .foregroundStyle(PausePathPalette.ink.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if typeSize.isAccessibilitySize {
                VStack(spacing: 9) { emptyGroupActions }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) { emptyGroupActions }
                    VStack(spacing: 9) { emptyGroupActions }
                }
            }
            Label("Groups are private. Ask a member for an invite code.", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(PausePathPalette.teal.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(PausePathPalette.teal.opacity(0.10)))
    }

    @ViewBuilder private var emptyGroupActions: some View {
        Button {
            communityComposerRoute = CommunityComposerRoute(joining: true, inviteCode: "")
        } label: {
            Label("Join with code", systemImage: "person.badge.plus")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .foregroundStyle(PausePathPalette.ink)
        .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 15))
        .accessibilityHint("Enter an invite code from a community member")

        Button {
            communityComposerRoute = CommunityComposerRoute(joining: false, inviteCode: "")
        } label: {
            Label("Start a group", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .foregroundStyle(PausePathPalette.teal)
        .background(PausePathPalette.background, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(PausePathPalette.teal.opacity(0.18)))
    }

    private var communityWelcomeArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 19).fill(PausePathPalette.teal.gradient)
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                let trail = Path { path in
                    path.move(to: CGPoint(x: width * 0.38, y: height * 0.61))
                    path.addCurve(to: CGPoint(x: width - 51, y: height * 0.5),
                                  control1: CGPoint(x: width * 0.56, y: height * 0.56),
                                  control2: CGPoint(x: width * 0.64, y: height * 0.34))
                }
                trail.stroke(PausePathPalette.background.opacity(0.22),
                             style: StrokeStyle(lineWidth: 10, lineCap: .round))
                trail.stroke(PausePathPalette.lime,
                             style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            HStack(spacing: -10) {
                ForEach(0..<3) { index in
                    Image(systemName: index == 1 ? "figure.walk" : "person.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(index == 1 ? PausePathPalette.ink : PausePathPalette.teal)
                        .frame(width: 44, height: 44)
                        .background(index == 1 ? PausePathPalette.lime : PausePathPalette.background, in: Circle())
                        .overlay(Circle().strokeBorder(PausePathPalette.teal, lineWidth: 2))
                }
                Spacer()
                Image(systemName: "flag.checkered")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(PausePathPalette.teal)
                    .frame(width: 42, height: 42)
                    .background(PausePathPalette.lime, in: Circle())
                    .overlay(Circle().strokeBorder(PausePathPalette.background.opacity(0.85), lineWidth: 2))
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 86)
        .accessibilityHidden(true)
    }

    private var communityPossibilities: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What can a group do?")
                .font(.headline).foregroundStyle(PausePathPalette.teal)
            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) { communityPossibilityItems }
            } else {
                HStack(spacing: 8) { communityPossibilityItems }
            }
        }
    }

    @ViewBuilder private var communityPossibilityItems: some View {
        possibility("Plan walks", icon: "map")
        possibility("Share goals", icon: "flag")
        possibility("Cheer each other", icon: "hands.clap")
    }

    private func possibility(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PausePathPalette.teal)
                .frame(width: 28, height: 28)
                .background(PausePathPalette.lime.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PausePathPalette.teal)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(9)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 17))
    }

    private func groupCard(_ community: WalkingCommunity) -> some View {
        let deepTeal = Color(red: 0.025, green: 0.23, blue: 0.24)
        return VStack(alignment: .leading, spacing: 15) {
            NavigationLink { CommunityHubView(community: community) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        Text(String(community.name.prefix(1)).uppercased())
                            .font(.title3.bold())
                            .foregroundStyle(deepTeal)
                            .frame(width: 48, height: 48)
                            .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityHidden(true)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.13), in: Circle())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(community.name)
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundStyle(.white).lineLimit(2)
                        Text("\(community.member_count) members")
                            .font(.caption).foregroundStyle(.white.opacity(0.72))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            if let walk = community.next_walk {
                Label(walk.title, systemImage: "calendar")
                    .font(.caption.weight(.medium)).foregroundStyle(PausePathPalette.lime).lineLimit(1)
            } else {
                Text("No walk planned yet").font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            HStack(spacing: 8) {
                NavigationLink { CommunityHubView(community: community, initialSection: "Walks") } label: {
                    Label("Walks", systemImage: "figure.walk").frame(maxWidth: .infinity, minHeight: 44)
                }
                NavigationLink { CommunityHubView(community: community, initialSection: "Goals") } label: {
                    Label(community.active_goal_count.map { "Goals \($0)" } ?? "Goals", systemImage: "flag")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24).fill(deepTeal.gradient)
                .overlay {
                    AdventureContours().stroke(.white.opacity(0.07), lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        }
    }

    private var socialShortcuts: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            NavigationLink { FriendsSettingsView() } label: {
                socialShortcut("Find friends", icon: "person.2.fill", detail: "Search people")
            }
            NavigationLink { SocialInboxView() } label: {
                socialShortcut("Inbox", icon: "tray.fill", detail: social.unread > 0 ? "\(social.unread) new" : "Invites & news")
            }
        }
        .buttonStyle(.plain)
    }

    private func socialShortcut(_ title: String, icon: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.headline).foregroundStyle(PausePathPalette.teal)
                .frame(width: 38, height: 38)
                .background(PausePathPalette.lime.opacity(0.24), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var sharePrompt: some View {
        Button { showingPostComposer = true } label: {
            HStack(spacing: 12) {
                Text(String((profile.username ?? "P").prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(PausePathPalette.lime)
                    .frame(width: 48, height: 48)
                    .background(PausePathPalette.teal, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Have something to share?")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
                    Text("Post an update to your group")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil")
                    .font(.headline).foregroundStyle(PausePathPalette.teal)
                    .frame(width: 38, height: 38)
                    .background(PausePathPalette.lime.opacity(0.32), in: Circle())
            }
            .padding(16)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(PausePathPalette.teal.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Write a post for one of your groups")
    }

    private var feedSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Group feed").font(.title2.bold()).foregroundStyle(PausePathPalette.teal)
                Spacer()
                if feedLoading { ProgressView().controlSize(.small) }
                else if let lastFeedRefresh {
                    Text("Updated \(lastFeedRefresh, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let feedMessage {
                HStack {
                    Text(feedMessage).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") {
                        guard let owner = account.userID else { return }
                        Task { await loadFeed(groups: communities, owner: owner, revision: communityRevision) }
                    }
                }
            }
            if feed.isEmpty && feedLoading {
                ProgressView("Loading updates…")
                    .frame(maxWidth: .infinity, minHeight: 100)
            } else if feed.isEmpty && feedMessage != nil {
                ContentUnavailableView("Updates unavailable", systemImage: "wifi.exclamationmark", description: Text("Pull down or tap Retry to load group posts."))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            } else if feed.isEmpty {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: -10) {
                        Image(systemName: "text.bubble.fill")
                            .foregroundStyle(PausePathPalette.lime)
                            .frame(width: 44, height: 44)
                            .background(PausePathPalette.teal, in: Circle())
                        Image(systemName: "heart.fill")
                            .foregroundStyle(PausePathPalette.teal)
                            .frame(width: 44, height: 44)
                            .background(PausePathPalette.lime, in: Circle())
                    }
                    Text("Start the conversation")
                        .font(.headline).foregroundStyle(PausePathPalette.teal)
                    Text("There are no group posts yet. Share a walk, a small win, or a question.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Write the first post", systemImage: "square.and.pencil") {
                        showingPostComposer = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PausePathPalette.lime)
                    .foregroundStyle(PausePathPalette.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            } else {
                ForEach(feed) { item in feedCard(item) }
            }
        }
    }

    private func feedCard(_ item: CommunityFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Text(String(item.post.display_name.prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(PausePathPalette.teal)
                    .frame(width: 42, height: 42)
                    .background(PausePathPalette.lime.opacity(0.26), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.post.display_name).font(.subheadline.weight(.bold))
                    Text(CommunityHubView.dateLabel(item.post.created_at))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                NavigationLink { CommunityHubView(community: item.community, initialSection: "Posts") } label: {
                    Image(systemName: "arrow.up.right").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Open \(item.community.name) posts")
            }
            Text(item.community.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PausePathPalette.teal)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(PausePathPalette.lime.opacity(0.20), in: Capsule())
            Text(item.post.body).font(.body).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button {
                    Task { await toggleCheer(item) }
                } label: {
                    Label("\(item.post.cheers) cheers", systemImage: item.post.cheered ? "hands.clap.fill" : "hands.clap")
                }
                .disabled(reactingPostIDs.contains(item.id))
                Spacer()
                NavigationLink { CommunityHubView(community: item.community, initialSection: "Posts") } label: {
                    Label("Open in group", systemImage: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
            }
            .font(.subheadline)
            .buttonStyle(.plain)
            .foregroundStyle(PausePathPalette.teal)
        }
        .padding(17)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }

    private var sharingPreferences: some View {
        DisclosureGroup("Sharing preferences") {
            Toggle("Share my goal totals", isOn: $shareProgress)
            Text("Group goals can show totals. Routes, location, and Health data stay private.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline.weight(.semibold))
        .padding(16)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var filteredCommunities: [WalkingCommunity] {
        let query = communitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? communities : communities.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    private var upcomingGroups: [WalkingCommunity] {
        Array(communities.filter {
            guard let start = $0.next_walk.flatMap({ SocialAPI.date($0.starts_at) }) else { return false }
            return start > .now
        }.sorted {
            ($0.next_walk.flatMap { SocialAPI.date($0.starts_at) } ?? .distantFuture) <
            ($1.next_walk.flatMap { SocialAPI.date($0.starts_at) } ?? .distantFuture)
        }.prefix(3))
    }

    private var upcomingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Happening soon").font(.title2.bold()).foregroundStyle(PausePathPalette.teal)
            ForEach(upcomingGroups) { community in
                if let walk = community.next_walk {
                    NavigationLink { CommunityHubView(community: community, initialSection: "Walks") } label: {
                        HStack(spacing: 14) {
                            if let date = SocialAPI.date(walk.starts_at) {
                                VStack(spacing: 1) {
                                    Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                                        .font(.caption2.weight(.heavy))
                                    Text(date.formatted(.dateTime.day()))
                                        .font(.title2.bold())
                                }
                                .foregroundStyle(PausePathPalette.ink)
                                .frame(width: 58, height: 64)
                                .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 15))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(walk.title).font(.headline).foregroundStyle(PausePathPalette.teal).lineLimit(2)
                                Text(community.name).font(.subheadline).foregroundStyle(.secondary)
                                Text(CommunityHubView.dateLabel(walk.starts_at))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(PausePathPalette.teal)
                        }
                        .padding(15)
                        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("From your people").font(.title2.bold()).foregroundStyle(PausePathPalette.teal)
                Spacer()
                NavigationLink { SocialInboxView() } label: {
                    Text("See all").font(.subheadline.weight(.semibold))
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(social.notifications.prefix(3))) { notification in
                    NavigationLink { SocialInboxView() } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: activityIcon(notification.category))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PausePathPalette.teal)
                                .frame(width: 36, height: 36)
                                .background(PausePathPalette.lime.opacity(0.3), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(notification.message).font(.subheadline).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let date = SocialAPI.date(notification.created_at) {
                                    Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if notification.read_at == nil {
                                Circle().fill(PausePathPalette.lime).frame(width: 8, height: 8)
                                    .accessibilityLabel("Unread")
                            }
                        }
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    if notification.id != social.notifications.prefix(3).last?.id { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func activityIcon(_ category: String) -> String {
        switch category {
        case "walks": "calendar"
        case "goals": "flag.fill"
        case "invites": "person.crop.circle.badge.plus"
        default: "bell.fill"
        }
    }

    @MainActor private func loadFeed(groups: [WalkingCommunity], owner: String, revision: UUID) async {
        guard account.userID == owner, communityRevision == revision else { return }
        let token = UUID()
        feedLoadToken = token
        guard !groups.isEmpty else {
            feed = []; feedMessage = nil; feedLoading = false
            return
        }
        feedLoading = true
        var collected: [CommunityFeedItem] = []
        var failures = 0
        await withTaskGroup(of: [CommunityFeedItem]?.self) { tasks in
            var remaining = groups.dropFirst(3).makeIterator()
            for community in groups.prefix(3) {
                tasks.addTask { await Self.posts(in: community) }
            }
            for await result in tasks {
                if let result { collected += result }
                else { failures += 1 }
                if let next = remaining.next() {
                    tasks.addTask { await Self.posts(in: next) }
                }
            }
        }
        guard account.userID == owner, communityRevision == revision, feedLoadToken == token else { return }
        if failures < groups.count {
            feed = Array(collected.sorted {
                (SocialAPI.date($0.post.created_at) ?? .distantPast) > (SocialAPI.date($1.post.created_at) ?? .distantPast)
            }.prefix(20))
            lastFeedRefresh = .now
        }
        feedMessage = failures == 0 ? nil : (failures == groups.count ? "Updates could not load." : "Some groups could not refresh.")
        feedLoading = false
    }

    private static func posts(in community: WalkingCommunity) async -> [CommunityFeedItem]? {
        do {
            let data = try await PausePathAPI.request("api/v1/communities/\(community.id.uuidString)/posts", requiresAccount: true)
            let posts = try JSONDecoder().decode(CommunityPostList.self, from: data).posts
            return posts.map { CommunityFeedItem(community: community, post: $0) }
        } catch { return nil }
    }

    @MainActor private func toggleCheer(_ item: CommunityFeedItem) async {
        guard reactingPostIDs.insert(item.id).inserted else { return }
        defer { reactingPostIDs.remove(item.id) }
        do {
            _ = try await PausePathAPI.request("api/v1/communities/\(item.community.id.uuidString)/posts/\(item.id.uuidString)/cheer",
                                               body: ["cheered": !item.post.cheered], requiresAccount: true)
            guard let index = feed.firstIndex(where: { $0.id == item.id }) else { return }
            let current = feed[index].post
            feed[index].post = CommunityPost(id: current.id, body: current.body, created_at: current.created_at,
                                             display_name: current.display_name,
                                             cheers: max(0, current.cheers + (current.cheered ? -1 : 1)),
                                             cheered: !current.cheered, can_delete: current.can_delete)
        } catch { feedMessage = "Could not update that cheer. Try again." }
    }

    @MainActor private func refresh(force: Bool = false) async {
        guard account.isSignedIn else { return }
        if busy { refreshAgain = refreshAgain || force; return }
        guard force || CommunityFreshness.shouldRefresh(lastLoaded: lastCommunityRefresh) else { return }
        let revision = UUID(); communityRevision = revision; busy = true
        defer {
            busy = false
            if refreshAgain { refreshAgain = false; Task { await refresh(force: true) } }
        }
        let loaded: [WalkingCommunity]
        do {
            loaded = try await PausePathAPI.communities()
            guard communityRevision == revision, account.isSignedIn else { return }
            communities = loaded
            communityLoadMessage = nil; message = ""; lastCommunityRefresh = .now
            if let owner = account.userID {
                Task { await loadFeed(groups: loaded, owner: owner, revision: revision) }
            }
        } catch {
            guard communityRevision == revision else { return }
            communityLoadMessage = communityErrorMessage(error)
            return
        }
        guard !loaded.isEmpty, let progressOwner = account.userID else { return }
        let removalKey = "pausepath.pendingProgressRemoval." + progressOwner
        guard shareProgress || UserDefaults.standard.object(forKey: removalKey) as? Bool != false else { return }
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
                case .success(let list): loadedTasks[id] = list
                case .failure: break
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
        if loadedTasks.count < loaded.count {
            message = shareProgress ? "Some goal totals could not refresh. Pull down to retry." : "Removing shared totals is not finished. Pull down to retry."
        }
        do {
            let changed: Set<UUID>
            if shareProgress { changed = try await PausePathAPI.syncChallengeProgress(walks: walks, groups: loaded, tasks: loadedTasks) }
            else { changed = try await PausePathAPI.clearChallengeProgress(groups: loaded, tasks: loadedTasks) }
            if !shareProgress && loadedTasks.count == loaded.count { UserDefaults.standard.set(false, forKey: removalKey) }
            if !changed.isEmpty {
                let summaries = try await PausePathAPI.communities()
                guard communityRevision == revision else { return }; communities = summaries
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
        membershipConfirmation = "\(community.name) is ready"
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
        membershipConfirmation = "You joined \(community.name)"
        return community
    }

}


struct WeeklySuggestionsView: View {
    let preferences: RoutePreferences
    @AppStorage("pausepath.weeklyChallengeDeck") private var weeklyChallengeData = Data()
    @AppStorage("pausepath.weeklyChallengeWeek") private var challengeWeekKey = ""
    @AppStorage("pausepath.weeklyChallengeRefreshes") private var weeklyRefreshesUsed = 0
    @AppStorage("pausepath.weeklyChallengeRefreshWeek") private var refreshWeekKey = ""
    @AppStorage("pausepath.monthlyChallengePoints") private var monthlyPoints = 0
    @AppStorage("pausepath.challengePointsMonth") private var pointsMonthKey = ""
    @State private var weeklyChallenges: [WeeklyPersonalChallenge] = []
    @AppStorage("pausepath.weeklyChallengeRewards") private var rewardLedgerData = Data()
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @Environment(\.scenePhase) private var scenePhase
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Weekly suggestions", systemImage: "sparkles").font(.headline)
                Spacer()
                Label("\(monthlyPoints) pts this month", systemImage: "star.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
            }
            ForEach(weeklyChallenges) { challenge in
                let progress = weeklyProgress(for: challenge)
                let complete = progress >= challenge.target
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(challenge.title).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(challengeProgressLabel(challenge, progress: progress))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(complete ? Color.green : Color.secondary)
                    }
                    SegmentedChallengeProgress(value: progress, total: challenge.target)
                        .frame(height: 8)
                        .accessibilityLabel("\(challengeProgressLabel(challenge, progress: progress)) complete")
                    HStack {
                        if complete {
                            Label("Earned 10 points", systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        } else {
                            Label("10 points", systemImage: "star")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)
                if challenge.id != weeklyChallenges.last?.id { Divider() }
            }
            HStack {
                if weeklyChallenges.isEmpty {
                    Text("No suggestions available.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh · \(max(0, 2 - weeklyRefreshesUsed)) left", systemImage: "arrow.clockwise") { refreshWeeklyChallenges() }
                    .font(.caption.weight(.semibold))
                    .disabled(weeklyRefreshesUsed >= 2)
            }
        }
        .padding(16).background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
            .onAppear { loadWeeklyChallenges() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { loadWeeklyChallenges() } }
            .onChange(of: trackedWalkData) { _, _ in loadWeeklyChallenges() }
            .onChange(of: preferences) { _, _ in personalizeUnstartedChallenges() }
            .onChange(of: profileData) { _, _ in personalizeUnstartedChallenges() }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathWalkRecorded)) { _ in loadWeeklyChallenges() }
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
           var decoded = try? JSONDecoder().decode([WeeklyPersonalChallenge].self, from: weeklyChallengeData), decoded.count <= 2 {
            for index in decoded.indices where decoded[index].kind == "distance_km" &&
                ["Walk a distance that fits your route preferences", "Walk your preferred distance"].contains(decoded[index].title) {
                decoded[index].kind = "single_distance_km"
            }
            weeklyChallenges = decoded
            storeWeeklyChallenges()
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
            ("Finish one walk", "walks", 1),
            ("Walk a new route", "new_routes", 1),
            ("Walk your preferred distance", "single_distance_km", suggestedDistance),
            ("Complete two walks", "walks", 2),
            ("Walk two new routes", "new_routes", 2),
            ("Walk 2 km total", "distance_km", 2),
            ("Finish three walks", "walks", 3)
        ]
        let available = ideas.filter { !excluding.contains($0.0) }.shuffled()
        return available.prefix(2).map { WeeklyPersonalChallenge(title: $0.0, kind: $0.1, target: $0.2) }
    }
    private var suggestedDistanceTarget: Double {
        let preferredDistance = min(5, max(0.5, preferences.distanceMeters / 1_000))
        return profile.goal.prefersGentlerRoutes ? min(preferredDistance, 0.5) : preferredDistance
    }
    private func personalizeUnstartedChallenges() {
        for index in weeklyChallenges.indices where ["Walk a distance that fits your route preferences", "Walk your preferred distance"].contains(weeklyChallenges[index].title) && !weeklyChallenges[index].pointsAwarded {
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
        let displayed = min(progress, challenge.target)
        if challenge.kind == "distance_km" || challenge.kind == "single_distance_km" {
            return String(format: "%.1f / %.1f km", displayed, challenge.target)
        }
        return "\(Int(displayed)) / \(Int(challenge.target))"
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

private struct CommunityQuickPostSheet: View {
    @Environment(\.dismiss) private var dismiss
    let communities: [WalkingCommunity]
    @State private var selectedGroupID: UUID
    @State private var bodyText = ""
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var errorMessage = ""

    init(communities: [WalkingCommunity]) {
        self.communities = communities
        _selectedGroupID = State(initialValue: communities.first?.id ?? UUID())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Share with") {
                    if communities.count > 1 {
                        Picker("Group", selection: $selectedGroupID) {
                            ForEach(communities) { community in
                                Text(community.name).tag(community.id)
                            }
                        }
                        .onChange(of: selectedGroupID) { _, _ in requestID = UUID() }
                    } else {
                        Text(communities.first?.name ?? "Your group")
                    }
                }
                Section("Your update") {
                    TextField("What would you like to share?", text: $bodyText, axis: .vertical)
                        .lineLimit(4...8)
                        .onChange(of: bodyText) { _, _ in requestID = UUID() }
                    Text("\(bodyText.count)/280 characters")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        Task { await post() }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text(busy ? "Sharing…" : "Share update")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PausePathPalette.lime)
                    .foregroundStyle(PausePathPalette.ink)
                    .disabled(busy || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || bodyText.count > 280)
                    if !errorMessage.isEmpty {
                        Text(errorMessage).font(.callout).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Your update is visible to members of the selected group.")
                }
            }
            .pausePathSurface()
            .navigationTitle("Share an update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(busy)
            } }
            .interactiveDismissDisabled(busy)
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor private func post() async {
        guard !busy, communities.contains(where: { $0.id == selectedGroupID }) else { return }
        let message = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 280 else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await PausePathAPI.request("api/v1/communities/\(selectedGroupID.uuidString)/posts",
                                               body: ["body": message, "request_id": requestID.uuidString], requiresAccount: true)
            dismiss()
        } catch { errorMessage = communityErrorMessage(error) }
    }
}

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
                let requestedJoin = startsWithJoin || !initialInviteCode.isEmpty
                if let restored = try? JSONDecoder().decode(CommunitySubmissionDraft.self, from: savedDraft), restored.ownerID == (account.userID ?? "signed-out") {
                    draft = restored; username = restored.username
                    if restored.joining == requestedJoin { name = restored.name; code = restored.code }
                } else { username = initialUsername }
                isJoining = requestedJoin
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
    @State private var name = "Walk three times this week"
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
                    Button("One walk together", systemImage: "figure.walk") { name = "One walk together"; metric = "walks"; target = 1 }
                    Button("Explore somewhere new", systemImage: "map") { name = "Try a new route"; metric = "new_routes"; target = 1 }
                    Text("Choose a goal and change it whenever you like.").font(.caption).foregroundStyle(.secondary)
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
    let route_snapshot: SharedRouteSnapshot?
    let meeting_location: SharedRoutePoint?
}
private struct CommunityPost: Decodable, Identifiable, Sendable {
    let id: UUID
    let body: String
    let created_at: String
    let display_name: String
    let cheers: Int
    let cheered: Bool
    let can_delete: Bool
}
private struct CommunityFeedItem: Identifiable, Sendable {
    let community: WalkingCommunity
    var post: CommunityPost
    var id: UUID { post.id }
}
private struct CommunityMember: Decodable, Identifiable {
    let user_id: String?
    let member_id: String?
    let display_name: String
    let is_owner: Bool?
    let is_self: Bool?
    var id: String { member_id ?? user_id ?? display_name }
}
private struct CommunityWalkList: Decodable { let walks: [CommunityWalkPlan] }
private struct CommunityPostList: Decodable, Sendable { let posts: [CommunityPost] }
private struct CommunityMemberList: Decodable {
    let members: [CommunityMember]
    let viewer_is_owner: Bool?
    let community_name: String?
}
private struct CommunityPendingAction: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    var body: [String: Any] = [:]
    var closes = false
}

private struct CommunityHubNavigation: View {
    @Binding var selection: String
    @Environment(\.dynamicTypeSize) private var typeSize
    private let primary = ["Walks", "Goals", "Posts"]
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker("Group section", selection: $selection) {
                    ForEach(["Walks", "Goals", "Posts", "Members", "Settings"], id: \.self) { title in
                        Text(title).tag(title)
                    }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 4) {
                    ForEach(primary, id: \.self) { title in
                        Button(title) { selection = title }
                            .accessibilityAddTraits(selection == title ? [.isSelected] : [])
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selection == title ? PausePathPalette.ink : PausePathPalette.teal)
                            .background(selection == title ? PausePathPalette.lime : Color.clear, in: Capsule())
                    }
                    Menu {
                        Button("Members", systemImage: "person.2") { selection = "Members" }
                        Button("Settings", systemImage: "gearshape") { selection = "Settings" }
                    } label: {
                        Text(selection == "Members" || selection == "Settings" ? selection : "More")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selection == "Members" || selection == "Settings" ? PausePathPalette.ink : PausePathPalette.teal)
                            .background(selection == "Members" || selection == "Settings" ? PausePathPalette.lime : Color.clear, in: Capsule())
                    }.accessibilityLabel("Members and group settings")
                }.font(.subheadline.weight(.semibold)).buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(PausePathPalette.background)
    }
}

struct CommunityHubView: View {
    let community: WalkingCommunity
    @Environment(\.dismiss) private var dismiss
    @State private var hubSection = "Walks"
    @State private var showingInvite = false
    @State private var composingPost = false
    @State private var showGoalComposer = false
    @State private var editingGoal: WalkingCommunityChallenge?
    @State private var goalFilter = CommunityGoalState.active
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastSectionRefresh: [String: Date] = [:]
    @State private var displayName = ""
    @State private var viewerIsOwner: Bool?
    private var isOwner: Bool { viewerIsOwner ?? (community.is_owner == true) }
    @State private var loadingSections = Set<String>()
    private var loading: Bool { loadingSections.contains(hubSection) }
    @State private var plans: [CommunityWalkPlan] = []
    @State private var posts: [CommunityPost] = []
    @State private var members: [CommunityMember] = []
    @State private var tasks: [WalkingCommunityChallenge] = []
    @State private var busy = false
    @State private var message = ""
    @State private var loadFailure = false
    @State private var newName = ""
    @State private var postText = ""
    @State private var postRequest = UUID()
    @State private var showWalkComposer = false
    @State private var invitingToWalk: CommunityWalkPlan?
    @State private var pending: CommunityPendingAction?
    init(community: WalkingCommunity, initialSection: String = "Walks") {
        self.community = community
        _hubSection = State(initialValue: initialSection)
    }
    private var base: String { "api/v1/communities/" + community.id.uuidString }
    var body: some View {
        Form {
            if hubSection == "Walks" { walkSection }
            else if hubSection == "Goals" { taskSection }
            else if hubSection == "Posts" { feedSection }
            else if hubSection == "Members" { memberSection }
            else { managementSection }
            if !message.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.circle").font(.callout)
                    if loadFailure {
                        Button("Retry this section") { Task { await load(force: true) } }.disabled(loading || busy)
                    } else {
                        Button("Dismiss") { message = "" }
                    }
                }
            }
            if loading { ProgressView("Refreshing your community…") }
        }.id(hubSection).pausePathSurface().navigationTitle(displayName.isEmpty ? community.name : displayName).navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                CommunityHubNavigation(selection: $hubSection)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Invite", systemImage: "person.badge.plus") { showingInvite = true }
                    .accessibilityLabel("Invite someone")
            } }
            .sheet(item: $invitingToWalk) { FriendsWalkInviteView(walkID: $0.id) }
            .sheet(isPresented: $showingInvite) {
                NavigationStack {
                    ScrollView { CommunityInviteCard(code: community.invite_code).padding(20) }
                        .pausePathSurface().navigationTitle("Invite someone").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingInvite = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .disabled(busy)
            .task { displayName = community.name; newName = community.name }
            .task(id: hubSection) { await load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await load(force: true) } }
            }
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
                    if let route = plan.route_snapshot {
                        DisclosureGroup("Route map & \(route.stops.count) planned stops") {
                            SharedGroupRouteView(route: route, meeting: plan.meeting_location)
                            Text("\(route.distance_meters / 1000, specifier: "%.1f") km · about \(Int(route.estimated_seconds / 60)) min").font(.subheadline)
                            Text("Shared plan. Check current stop access, hours and terrain before walking.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let meeting = plan.meeting_location, let coordinate = meeting.coordinate {
                        Map { Marker("Meeting point", coordinate: coordinate.mapCoordinate) }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if plan.cancelled { Label("Cancelled", systemImage: "xmark.circle") }
                    else {
                        Text("\(plan.attendees) going").font(.caption)
                        Button(plan.attending ? "Cancel my RSVP" : "I'm going", systemImage: plan.attending ? "checkmark.circle.fill" : "person.badge.plus") {
                            Task { await perform("walks/\(plan.id)/rsvp", body: ["attending": !plan.attending]) }
                        }.buttonStyle(.bordered)
                        if plan.can_manage {
                            Button("Invite friends", systemImage: "person.badge.plus") { invitingToWalk = plan }
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
            TextField("Write an update…", text: $postText, axis: .vertical).lineLimit(2...5)
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
            Picker("Goals", selection: $goalFilter) {
                ForEach(CommunityGoalState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            ForEach(tasks.filter { goalState($0) == goalFilter }) { goal in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        Text(goal.name).font(.headline)
                        Spacer()
                        if goal.can_delete == true {
                            if goal.archived_at == nil {
                                Button("Edit") { editingGoal = goal }.font(.subheadline.weight(.semibold)).frame(minHeight: 44).buttonStyle(.borderless)
                            }
                            Menu {
                                Button(goal.archived_at == nil ? "Archive goal" : "Restore goal", systemImage: "archivebox") {
                                    Task { await perform("challenges/\(goal.id)/archive", body: ["archived": goal.archived_at == nil]) }
                                }
                            } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("Archive or restore \(goal.name)")
                            Button(role: .destructive) {
                                pending = CommunityPendingAction(title: "Delete this goal and its progress?", path: "challenges/\(goal.id)/delete")
                            } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                                .buttonStyle(.borderless).accessibilityLabel("Delete \(goal.name)")
                        }
                    }
                    if goalState(goal) == .archived { Label("Archived", systemImage: "archivebox").font(.caption).foregroundStyle(.secondary) }
                    else if goalState(goal) == .completed { Label("Completed", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(PausePathPalette.teal) }
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
            if !loading && tasks.filter({ goalState($0) == goalFilter }).isEmpty { Text("No \(goalFilter.rawValue.lowercased()) goals.").foregroundStyle(.secondary) }
        }
    }
    private func goalState(_ goal: WalkingCommunityChallenge) -> CommunityGoalState {
        let progress = goal.shared_goal == true ? (goal.group_progress ?? 0) : (goal.my_progress ?? 0)
        return .classify(archived: goal.archived_at != nil, progress: progress, target: goal.target)
    }
    private var memberSection: some View {
        Section("Members") {
            ForEach(members) { member in
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(PausePathPalette.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.display_name).font(.headline)
                        if member.is_owner == true { Label("Owner", systemImage: "crown.fill").font(.caption).foregroundStyle(PausePathPalette.teal) }
                        if member.is_self == true { Text("You").font(.caption).foregroundStyle(.secondary) }
                    }
                }.padding(.vertical, 6)
            }
            if members.isEmpty && !loading { Text("Members could not be loaded. Pull down to retry.").foregroundStyle(.secondary) }
        }
    }
    private var managementSection: some View {
        Section("Community settings") {
            if isOwner {
                TextField("Community name", text: $newName)
                Button("Save name") { Task { await perform("rename", body: ["name": newName]) } }
                    .disabled(!(2...60).contains(newName.trimmingCharacters(in: .whitespacesAndNewlines).count))
                ForEach(members.filter { $0.is_self != true && $0.user_id != nil }) { member in
                    Menu(member.display_name) {
                        Button("Transfer ownership") { pending = CommunityPendingAction(title: "Make \(member.display_name) the owner?", path: "transfer", body: ["user_id": member.user_id ?? ""], closes: true) }
                        Button("Remove member", role: .destructive) { pending = CommunityPendingAction(title: "Remove \(member.display_name)?", path: "members/remove", body: ["user_id": member.user_id ?? ""]) }
                    }
                }
                Text("Transfer ownership to a member before leaving, or delete the group.").font(.caption).foregroundStyle(.secondary)
                Button("Delete community", role: .destructive) { pending = CommunityPendingAction(title: "Delete this community and all group content?", path: "delete", closes: true) }
            } else {
                Button("Leave community", role: .destructive) { pending = CommunityPendingAction(title: "Leave this community? Your posts, RSVPs, and shared totals will be removed.", path: "leave", closes: true) }
            }
        }
    }
    @MainActor private func refreshDirectory(owner: String) async throws {
        let directory = try JSONDecoder().decode(CommunityMemberList.self, from: await PausePathAPI.request(base + "/members", requiresAccount: true))
        try Task.checkCancellation()
        guard PausePathAccount.shared.userID == owner else { throw CancellationError() }
        members = directory.members
        viewerIsOwner = directory.viewer_is_owner
        if let title = directory.community_name {
            if newName == displayName || displayName.isEmpty { newName = title }
            displayName = title
        }
    }
    @MainActor private func load(force: Bool = false) async {
        let section = hubSection
        guard !loadingSections.contains(section), force || CommunityFreshness.shouldRefresh(lastLoaded: lastSectionRefresh[section]), let owner = PausePathAccount.shared.userID else { return }
        loadingSections.insert(section)
        defer { loadingSections.remove(section) }
        message = ""; loadFailure = false
        do {
            if force && section != "Members" && section != "Settings" { try? await refreshDirectory(owner: owner) }
            try Task.checkCancellation()
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
            case "Members", "Settings":
                try await refreshDirectory(owner: owner)
            default: break
            }
            try Task.checkCancellation()
            lastSectionRefresh[section] = .now
        } catch {
            if !Task.isCancelled, PausePathAccount.shared.userID == owner, hubSection == section {
                message = "\(section) could not load. Pull down or tap Retry."
                loadFailure = true
            }
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
                await SocialActivityStore.shared.refresh()
            }
            return true
        } catch { message = communityErrorMessage(error); loadFailure = false; return false }
    }
    static func dateLabel(_ raw: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable"
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
