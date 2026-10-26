import SwiftUI
import Charts
import PhotosUI
import MapKit
import UserNotifications
import UniformTypeIdentifiers

enum DailyRecapNotifications {
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do { return try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { return false }
    }

    static func schedule() async {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: "pausepath.personalProfile"),
              let profile = try? JSONDecoder().decode(PausePathProfile.self, from: data),
              profile.dailyRecapNotifications else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        center.removePendingNotificationRequests(withIdentifiers: ["pausepath.daily-recap"])
        let content = UNMutableNotificationContent()
        content.title = "Your PausePath activity recap is ready"
        content.body = "See your walking summary in My Path whenever it suits you."
        content.sound = .default
        var date = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        date.hour = 20; date.minute = 0
        var fireDate = Calendar.current.date(from: date) ?? Date()
        if fireDate <= Date() { fireDate = Calendar.current.date(byAdding: .day, value: 1, to: fireDate) ?? Date().addingTimeInterval(86400) }
        let triggerDate = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        do { try await center.add(UNNotificationRequest(identifier: "pausepath.daily-recap", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: triggerDate, repeats: false))) }
        catch {
            #if DEBUG
            print("PausePath recap notification scheduling failed: \(error)")
            #endif
        }
    }

    static func disable() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pausepath.daily-recap"])
    }
}

struct ContentView: View {
    @State private var preferences = RoutePreferences()
    @State private var selectedTab = 0
    @AppStorage("pausepath.preferences") private var preferencesData = Data()
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.pendingCommunityInvite") private var pendingCommunityInvite = ""
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    @State private var social = SocialActivityStore.shared
    @State private var account = PausePathAccount.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("pausepath.pendingInbox") private var pendingInbox = false
    let health: HealthActivityStore
    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView(preferences: preferences, profile: profile, health: health).tabItem { Label("Explore", systemImage: "map.fill") }.tag(0)
            CommunityChallengesView(preferences: preferences).tabItem { Label("Community", systemImage: "person.3.fill") }.tag(1)
            MyPathView(preferences: preferences, health: health).tabItem { Label("My Path", systemImage: "chart.bar.fill") }.tag(2)
            ProfileSettingsView(preferences: $preferences, health: health).tabItem { Label("Profile", systemImage: "person.crop.circle") }.badge(social.unread).tag(3)
        }.tint(PausePathPalette.teal)
        .task(id: account.userID) {
            guard account.isSignedIn else { social.reset(); return }
            while !Task.isCancelled {
                if scenePhase == .active { await social.refresh() }
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .onChange(of: account.userID) { _, _ in social.reset() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await social.refresh() } } }
        .onReceive(NotificationCenter.default.publisher(for: .pausePathShowInbox)) { _ in pendingInbox = true }
        .sheet(isPresented: $pendingInbox) { NavigationStack { SocialInboxView().toolbar { Button("Done") { pendingInbox = false } } } }
        .toolbarBackground(PausePathPalette.background, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .onAppear {
            if !pendingCommunityInvite.isEmpty { selectedTab = 1 }
            if var saved = try? JSONDecoder().decode(RoutePreferences.self, from: preferencesData) {
                saved.departure = Date()
                preferences = saved
            } else {
                profile.goal.applyRouteDefaults(to: &preferences)
            }
        }
        .task {
            await PausePathAccount.shared.restoreSessionIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pausePathOpenExplore)) { _ in selectedTab = 0 }
        .onReceive(NotificationCenter.default.publisher(for: .pausePathShowProgress)) { _ in selectedTab = 2 }
        .onChange(of: preferences) { preferencesData = (try? JSONEncoder().encode(preferences)) ?? Data() }
    }
}

struct ProfileSettingsView: View {
    @Binding var preferences: RoutePreferences
    let health: HealthActivityStore
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.trackedWalks") private var trackedData = Data()
    @AppStorage("pausepath.profilePhoto") private var photoData = Data()
    @AppStorage("pausepath.weather.openMeteo.guidance.enabled") private var weatherEnabled = true
    @AppStorage("pausepath.weather.openMeteo.walkUpdates.enabled") private var weatherUpdates = true
    @AppStorage("pausepath.demoMode") private var demoMode = false
    @AppStorage("pausepath.appearance") private var appearanceRawValue = PausePathAppearance.light.rawValue
    @AppStorage(DistanceDisplayUnit.storageKey) private var distanceUnitRaw = DistanceDisplayUnit.kilometers.rawValue
    @State private var photo: PhotosPickerItem?
    @State private var photoError: String?
    @State private var account = PausePathAccount.shared
    @Environment(\.openURL) private var openURL
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    private var name: String { profile.username.flatMap { $0.isEmpty ? nil : $0 } ?? "Walker" }
    private var weeklyWalks: [TrackedWalk] {
        guard let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date()) else { return [] }
        return ((try? JSONDecoder().decode([TrackedWalk].self, from: trackedData)) ?? []).filter { interval.contains($0.date) }
    }
    private var minutes: Int { Int(weeklyWalks.reduce(0) { $0 + $1.activeSeconds } / 60) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center, spacing: 18) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                Group {
                                    if let image = UIImage(data: photoData) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Text(String(name.prefix(1)).uppercased()).font(.system(size: 34, weight: .semibold, design: .rounded))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                                    }
                                }.frame(width: 76, height: 76).clipShape(Circle())
                                Image(systemName: "camera.fill").font(.caption).padding(7)
                                    .background(PausePathPalette.ink, in: Circle()).foregroundStyle(.white)
                            }
                        }.accessibilityLabel("Choose profile photo")
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.title.bold()).foregroundStyle(PausePathPalette.teal)
                            NavigationLink("Edit profile") { ChangeUsernameView() }.font(.subheadline.weight(.semibold))
                        }
                        Spacer(minLength: 0)
                    }
                    if !photoData.isEmpty {
                        Button("Remove photo", role: .destructive) { photoData = Data(); photo = nil }.font(.caption)
                    }
                    if let photoError { Text(photoError).font(.caption).foregroundStyle(.secondary) }

                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Label("This week", systemImage: "sun.horizon.fill").font(.headline)
                            Spacer()
                            NavigationLink { GoalPreferencesEditor(preferences: $preferences) } label: {
                                Text("Adjust goal").font(.caption.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(PausePathPalette.lime, in: Capsule()).foregroundStyle(PausePathPalette.ink)
                            }
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 24) { walkMetric; minuteMetric }
                            VStack(alignment: .leading, spacing: 20) { walkMetric; minuteMetric }
                        }
                        Text(weeklyWalks.isEmpty ? "Completed PausePath walks will appear here." : "You can change your weekly goal at any time.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("PausePath-tracked walks · This device").font(.caption2).foregroundStyle(.secondary)
                    }.padding(22).background(PausePathPalette.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 26))

                    section("Made for you") {
                        NavigationLink { PlannerView(preferences: $preferences, health: health) } label: {
                            row("Walking preferences", detail: "\(preferences.terrain.rawValue) · Rest every \(Int(preferences.maximumRestGapMeters)) m", icon: "slider.horizontal.3")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { GoalPreferencesEditor(preferences: $preferences) } label: {
                            row("Your goals", detail: profile.goal.rawValue, icon: "scope")
                        }
                    }
                    section("Product demo") {
                        Toggle(isOn: $demoMode) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sample walking insights")
                                Text("Also show a labeled sample model in Insights and route suggestions. Your own walking trend stays separate.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(16)
                    }
                    section("Connected services") {
                        NavigationLink { healthSettings } label: {
                            row("Apple Health", detail: health.activities.isEmpty ? "Optional · Review access" : "\(health.activities.count) activities available", icon: "heart")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { weatherSettings } label: {
                            row("Weather", detail: weatherEnabled ? "Forecasts on" : "Forecasts off", icon: "cloud.sun")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { locationSettings } label: {
                            row("Location", detail: "Manage access in iOS Settings", icon: "location")
                        }
                    }
                    section("People & notifications") {
                        NavigationLink { FriendsSettingsView() } label: {
                            row("Friends", detail: "Find people · Requests · Privacy", icon: "person.2")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { SocialInboxView() } label: {
                            row("Community inbox", detail: "Invitations, walk and goal updates", icon: "tray")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { NotificationSettingsView() } label: {
                            row("Notifications", detail: "Inbox preferences & walk reminders", icon: "bell")
                        }
                    }
                    section("Saved areas & navigation") {
                        NavigationLink { SavedRoutesSettingsView(preferences: preferences) } label: {
                            row("Saved routes", detail: "Favorites, collections & repeat walks", icon: "heart")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { SavedAreasSettingsView() } label: {
                            row("Downloaded areas", detail: "On this device · up to 5 MB", icon: "square.and.arrow.down")
                        }
                    }
                    section("Distance units") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Distance units", selection: $distanceUnitRaw) {
                                ForEach(DistanceDisplayUnit.allCases) { unit in Text(unit.title).tag(unit.rawValue) }
                            }.pickerStyle(.segmented)
                            Text("Used for Explore routes and navigation.").font(.caption).foregroundStyle(.secondary)
                        }.padding(16)
                    }
                    section("Appearance") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("App appearance", selection: $appearanceRawValue) {
                                ForEach(PausePathAppearance.allCases) { appearance in
                                    Text(appearance.title).tag(appearance.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            Text("System follows your device appearance. Light and Dark keep PausePath in your chosen mode.")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 16) {
                                paletteSwatch("Mint", color: PausePathPalette.background)
                                paletteSwatch("Teal", color: PausePathPalette.teal)
                                paletteSwatch("Lime", color: PausePathPalette.lime)
                            }
                        }.padding(16)
                    }
                    section("Account & privacy") {
                        NavigationLink { AccountView() } label: {
                            row("Account settings", detail: account.isSignedIn ? account.sessionStatusText : "Sign in to join your community", icon: "person.crop.circle")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { privacySettings } label: {
                            row("Privacy & credits", detail: "Your data, your choices", icon: "hand.raised")
                        }
                    }
                    PathBadgeCollection(walks: (try? JSONDecoder().decode([TrackedWalk].self, from: trackedData)) ?? [])
                    Text("Built around you, one walk at a time.")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.bottom, 16)
                }.padding(20).frame(maxWidth: 620).frame(maxWidth: .infinity)
            }.pausePathSurface().navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: photo) {
                    guard let photo else { return }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                        try Task.checkCancellation()
                        let size = CGSize(width: 256, height: 256)
                        let renderer = UIGraphicsImageRenderer(size: size)
                        let scaled = renderer.image { _ in
                            let factor = max(size.width / image.size.width, size.height / image.size.height)
                            let target = CGSize(width: image.size.width * factor, height: image.size.height * factor)
                            image.draw(in: CGRect(x: (256-target.width)/2, y: (256-target.height)/2, width: target.width, height: target.height))
                        }
                        photoData = scaled.jpegData(compressionQuality: 0.8) ?? Data(); photoError = nil
                    } catch { if !Task.isCancelled { photoError = "Couldn’t load that photo. Try another image." } }
                }
        }
    }

    private var walkMetric: some View { metric(value: weeklyWalks.count, target: profile.weeklyWalkTarget, label: "walks") }
    private var minuteMetric: some View { metric(value: minutes, target: profile.weeklyMinutesTarget, label: "minutes") }
    private func metric(value: Int, target: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(value)").font(.system(.largeTitle, design: .rounded).weight(.semibold))
                .foregroundStyle(PausePathPalette.teal)
            Text("of \(target) \(label)").font(.subheadline).foregroundStyle(.secondary)
            ProgressView(value: Double(min(value, target)), total: Double(max(1, target))).tint(PausePathPalette.teal)
                .accessibilityLabel("\(label) this week").accessibilityValue("\(value) of \(target)")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(PausePathPalette.teal).padding(.leading, 4)
            VStack(spacing: 0, content: content).background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: PausePathPalette.corner))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(PausePathPalette.teal.opacity(0.10), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func row(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(PausePathPalette.teal)
                .frame(width: 40, height: 40).background(PausePathPalette.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(16).contentShape(Rectangle())
    }
    private func paletteSwatch(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
            Text(title).font(.caption)
        }
        .accessibilityElement(children: .combine)
    }
    private var healthSettings: some View {
        Form {
            Section { Text(health.status); Button(health.isLoading ? "Reading…" : "Connect / refresh Health") { Task { await health.connect() } }.disabled(health.isLoading) }
            Section { Text("Health activity stays on this device. History stays source-specific; walking-minute insights combine likely duplicate workouts only once."); Button("Clear session data", role: .destructive) { health.clear() } }
        }.pausePathSurface().navigationTitle("Apple Health")
    }
    private var weatherSettings: some View {
        Form {
            Section { Toggle("Route forecasts", isOn: $weatherEnabled); Toggle("Updates while walking", isOn: $weatherUpdates).disabled(!weatherEnabled) }
            Section { Text("Forecasts send approximate route locations to Open-Meteo. Walking updates check about every 15 minutes while navigation is active. Forecasts are cached in memory; Open-Meteo may retain request logs for 90 days."); Link("Provider privacy", destination: URL(string: "https://open-meteo.com/en/terms")!) }
        }.pausePathSurface().navigationTitle("Weather")
    }
    private var locationSettings: some View {
        Form {
            Section { Text("Location helps find nearby stops and guide your walk. An explicitly started walk can continue with the phone locked when enabled. Pause or End stops location tracking. Resume opens the app."); Button("Open iOS Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) } }
        }.pausePathSurface().navigationTitle("Location")
    }
    private var privacySettings: some View {
        Form {
            Section("Your profile") { Text("Your photo stays on this device. Your username is visible to communities you join; a nickname is welcome.") }
            Section("Your activity") { Text("Health data and tracked walks stay on this device. Community progress is shared only when you submit it. Route planning and nearby searches send the relevant map area or planned route to our services. Public stop snapshots are saved on this phone for up to seven days and can be cleared in Saved areas & navigation. Temporary Mapbox business results are not saved.") }
            Section("Map credits") {
                Text("Basemap and navigation: Apple Maps. Facilities: OpenStreetMap, Mapbox and the PausePath community.")
                Link("OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Link("Mapbox", destination: URL(string: "https://www.mapbox.com/about/maps/")!)
            }
        }.pausePathSurface().navigationTitle("Privacy & credits")
    }
}

private struct ChangeUsernameView: View {
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @State private var username = ""
    @State private var status = ""
    @State private var saving = false
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    private var cleanUsername: String { String(username.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32)) }

    var body: some View {
        Form {
            Section("Your PausePath username") {
                TextField("Username", text: $username)
                    .textContentType(.nickname).textInputAutocapitalization(.words).autocorrectionDisabled()
                Text("This is shown to members of communities you join. Use a nickname if you prefer.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Section { Text(status).font(.callout) } }
            Section {
                Button(saving ? "Saving…" : "Save Username") { Task { await save() } }
                    .disabled(cleanUsername.isEmpty || saving)
            }
        }
        .pausePathSurface()
        .navigationTitle("Change Username")
        .onAppear { username = profile.username ?? "" }
    }

    private func save() async {
        guard !cleanUsername.isEmpty else { return }
        saving = true; defer { saving = false }
        var updated = profile; updated.username = cleanUsername
        profileData = (try? JSONEncoder().encode(updated)) ?? profileData
        guard PausePathAccount.shared.isSignedIn else { status = "Saved on this device. Sign in to update your community username."; return }
        do {
            try await PausePathAPI.updateCommunityUsername(cleanUsername)
            status = "Username updated on this device and in your communities."
        } catch {
            status = "Saved on this device, but community usernames could not update: \(error.localizedDescription)"
        }
    }
}

private struct GoalPreferencesEditor: View {
    @Binding var preferences: RoutePreferences
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    var body: some View {
        Form {
            Section("Your goal") {
                Picker("What brings you to PausePath?", selection: Binding(get: { profile.goal }, set: { goal in
                    var updated = profile; updated.goal = goal
                    profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                    goal.applyRouteDefaults(to: &preferences)
                })) {
                    ForEach(PersonalGoalProfile.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Text(profile.goal.explanation).font(.caption).foregroundStyle(.secondary)
                Text("This choice is stored on this device and is never inferred from Health data.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Weekly goals") {
                Stepper("Weekly walks: \(profile.weeklyWalkTarget)", value: Binding(get: { profile.weeklyWalkTarget }, set: { value in var updated = profile; updated.weeklyWalkTarget = value; profileData = (try? JSONEncoder().encode(updated)) ?? profileData }), in: 1...14)
                Stepper("Weekly minutes: \(profile.weeklyMinutesTarget)", value: Binding(get: { profile.weeklyMinutesTarget }, set: { value in var updated = profile; updated.weeklyMinutesTarget = value; profileData = (try? JSONEncoder().encode(updated)) ?? profileData }), in: 10...600, step: 10)
                Toggle("Weekly active-calorie goal", isOn: Binding(get: { profile.weeklyActiveEnergyTargetKcal != nil }, set: { enabled in
                    var updated = profile
                    updated.weeklyActiveEnergyTargetKcal = enabled ? 500 : nil
                    profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                }))
                if let target = profile.weeklyActiveEnergyTargetKcal {
                    Stepper("\(target) active kcal", value: Binding(get: { target }, set: { value in
                        var updated = profile
                        updated.weeklyActiveEnergyTargetKcal = value
                        profileData = (try? JSONEncoder().encode(updated)) ?? profileData
                    }), in: 100...5000, step: 50)
                    Text("Progress uses available Apple Health daily active-energy readings across all activity. A planned route does not predict calories burned.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section { Text("PausePath does not assess medical recovery readiness or safe exertion. Follow your healthcare professional’s advice.").font(.footnote).foregroundStyle(.secondary) }
        }.pausePathSurface()
        .navigationTitle("Update Goals")
    }
}

struct PlannerView: View {
    @Binding var preferences: RoutePreferences
    var health: HealthActivityStore
    @State private var useHealthSpeed = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Route preferences").font(.title2.bold())
                    Text("Set distance, terrain, and rest-stop preferences for route suggestions.").foregroundStyle(.secondary)
                }
                Section("Your preferences") {
                    Picker("Goal", selection: $preferences.goal) { ForEach(WalkingGoal.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    VStack(alignment: .leading) {
                        Text("Desired distance: \(preferences.distanceMeters / 1000, specifier: "%.1f") km")
                        Slider(value: $preferences.distanceMeters, in: 400...5000, step: 100).accessibilityLabel("Desired distance in meters")
                    }
                    Picker("Terrain", selection: $preferences.terrain) { ForEach(TerrainPreference.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Text("Mostly flat: up to 3% grade. Gentle: up to 6%. These are preferences, not exertion guidance.").font(.caption).foregroundStyle(.secondary)
                    Stepper("Rest stops at most \(Int(preferences.maximumRestGapMeters)) m apart", value: $preferences.maximumRestGapMeters, in: 100...1000, step: 100)
                    DatePicker("Departure", selection: $preferences.departure)
                    ForEach(FacilityKind.allCases, id: \.self) { kind in
                        Toggle(kind.rawValue, isOn: Binding(get: { preferences.facilities.contains(kind) }, set: { if $0 { preferences.facilities.insert(kind) } else { preferences.facilities.remove(kind) } }))
                    }
                }
                RouteDifficultyFactorSettings()
                Section("Time estimate") {
                    Slider(value: $preferences.speedMetersPerSecond, in: 0.3...2, step: 0.1).disabled(useHealthSpeed).accessibilityLabel("Walking speed in meters per second")
                    Text("\(preferences.speedMetersPerSecond, specifier: "%.2f") m/s • excludes breaks")
                    if let speed = health.walkingSpeed {
                        Toggle("Use latest available Health walking speed", isOn: $useHealthSpeed)
                            .onChange(of: useHealthSpeed) { if useHealthSpeed { preferences.speedMetersPerSecond = speed } }
                    } else { Text("Manual estimate. Optional Health walking speed can be connected in My Path.").font(.caption) }
                }
                Section { Text("PausePath does not assess medical recovery readiness or safe exertion limits. Medical recovery decisions remain with your healthcare provider.").font(.footnote).foregroundStyle(.secondary) }
            }
            .pausePathSurface()
        .navigationTitle("Walking preferences")
            .onChange(of: health.walkingSpeed) {
                if useHealthSpeed, let speed = health.walkingSpeed { preferences.speedMetersPerSecond = speed }
                if health.walkingSpeed == nil { useHealthSpeed = false; preferences.speedMetersPerSecond = 1 }
            }
        }
    }
}


private struct PathActivity: Identifiable {
    let id: String
    let date: Date
    let title: String
    let kind: String
    let symbol: String
    let meters: Double
    let hasDistance: Bool
    let seconds: Double
    let steps: Double?
    let calories: Double?
    let heartRate: Double?
    let tracked: TrackedWalk?
    var isHealth: Bool { tracked == nil }
    var pace: String {
        guard hasDistance, meters > 0, seconds > 0 else { return "—" }
        let value = seconds / (meters / 1000)
        return String(format: "%d:%02d /km", Int(value) / 60, Int(value) % 60)
    }
    init(_ walk: TrackedWalk) {
        id = walk.id.uuidString; date = walk.date; title = walk.routeName; kind = walk.activityKind ?? "Walking"; symbol = walk.activityKind == "Running" ? "figure.run" : (walk.activityKind == "Hiking" ? "figure.hiking" : "figure.walk")
        meters = walk.distanceMeters; hasDistance = true; seconds = walk.activeSeconds; tracked = walk
        steps = walk.steps.map(Double.init); calories = nil; heartRate = nil
    }
    init(_ workout: WalkingActivity) {
        id = workout.id; date = workout.date; title = workout.kind; kind = workout.kind; symbol = workout.symbol
        meters = workout.meters ?? 0; hasDistance = workout.meters != nil; seconds = workout.seconds; steps = workout.steps
        calories = workout.calories; heartRate = workout.averageHeartRate; tracked = nil
    }
    var summary: String {
        let state = tracked.map { $0.completed ? "Completed" : "Ended early" } ?? "Recorded"
        return "\(state) a \(kind.lowercased()) session on \(date.formatted(date: .abbreviated, time: .shortened)): \(hasDistance ? String(format: "%.2f km", meters / 1000) : "distance not recorded") in \(Int(seconds / 60)) active minutes."
    }
}

struct MyPathView: View {
    let preferences: RoutePreferences
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let health: HealthActivityStore
    @AppStorage("pausepath.trackedWalks") private var trackedData = Data()
    @AppStorage("pausepath.walkFeedback") private var feedbackData = Data()
    @AppStorage("pausepath.demoMode") private var demoMode = false
    @State private var source = "PausePath"
    @State private var pathSection = "Overview"
    @State private var editingGoal = false
    @State private var showHealthExplanation = false
    @State private var period = 7
    @State private var kind = "All"
    @State private var historyDays = 0
    @AppStorage("pausepath.hiddenHealthWorkouts") private var hiddenHealthData = Data()
    @AppStorage("pausepath.personalGoal.metric") private var goalMetric = "distance"
    @AppStorage("pausepath.personalGoal.target") private var goalTarget = 5.0
    @AppStorage("pausepath.personalGoal.enabled") private var goalEnabled = true
    @Environment(\.scenePhase) private var pathScenePhase
    @State private var exportDocument = PathExportDocument(text: "")
    @State private var exporting = false
    @State private var exportMessage = ""
    private var walks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedData)) ?? [] }
    private var personalWalkingHistory: [WalkingHistoryEntry] {
        let feedback = (try? JSONDecoder().decode([WalkFeedback].self, from: feedbackData)) ?? []
        let hidden = (try? JSONDecoder().decode(Set<String>.self, from: hiddenHealthData)) ?? []
        let workouts = health.activities.filter { $0.kind == "Walking" && !hidden.contains($0.id) }
            .map { HealthWalkingRecord(id: $0.id, start: $0.date, seconds: $0.seconds, distanceMeters: $0.meters) }
        return WalkingHistoryBuilder.combine(tracked: walks, health: workouts, feedback: feedback)
    }
    private var walkingHistory: [WalkingHistoryEntry] {
        demoMode ? WalkingHistoryBuilder.sample() : personalWalkingHistory
    }
    private var milestones: PathMilestones { PathMilestones(walks: walks) }
    private var totalPathBadgeCount: Int { milestones.badges.count + 1 }
    private var activities: [PathActivity] {
        let all = source == "PausePath" ? walks.map(PathActivity.init) : health.activities.map(PathActivity.init)
        let hidden = (try? JSONDecoder().decode(Set<String>.self, from: hiddenHealthData)) ?? []
        return all.filter { (!($0.isHealth && hidden.contains($0.id))) && (pathSection != "History" || kind == "All" || $0.kind == kind) }.sorted { $0.date > $1.date }
    }
    private var recent: [PathActivity] {
        let start = Calendar.current.date(byAdding: .day, value: -(period - 1), to: Calendar.current.startOfDay(for: Date()))!
        return activities.filter { $0.date >= start && $0.date <= Date() }
    }
    private var recentPaths: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(source == "PausePath" ? "Recent paths" : "Recent activity").font(.headline)
                Spacer()
                sourceMenu
            }
            let items = Array(activities.prefix(3))
            if items.isEmpty {
                ContentUnavailableView("No activity yet", systemImage: "figure.walk", description: Text("Record a path in Explore or choose Apple Health as your source."))
                    .frame(minHeight: 140)
            } else {
                ForEach(items) { activity in
                    NavigationLink { PathJourneyDetail(activity: activity, health: health) } label: {
                        activityRow(activity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if activity.id != items.last?.id { Divider() }
                }
            }
            Button { pathSection = "History" } label: {
                Label("See all", systemImage: "arrow.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .tint(PausePathPalette.teal)
        }
        .padding(16)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 22))
    }
    private var daily: [HealthDay] {
        let start = Calendar.current.date(byAdding: .day, value: -(period - 1), to: Calendar.current.startOfDay(for: Date()))!
        return health.days.filter { $0.date >= start }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PathSectionPicker(titles: ["Overview", "History", "Insights"], selection: $pathSection, usesMaterialBackground: false)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if pathSection != "Overview" && !(demoMode && pathSection == "Insights") { sourceControls }
                    if pathSection == "Overview" {
                        recentPaths
                        if goalEnabled { personalGoal }
                        else {
                            Button("Set a weekly goal", systemImage: "plus.circle") { goalEnabled = true }.pathCard()
                        }
                        WeeklySuggestionsView(preferences: preferences)
                    } else if pathSection == "History" {
                        history
                    } else {
                        if demoMode {
                            walkingMinutesTrend
                            Text("The sample and your recorded trend are shown separately. The sample never replaces your data.")
                                .font(.callout).foregroundStyle(.secondary).pathCard()
                        } else {
                            if source == "Apple Health" { healthTotals }
                            walkingMinutesTrend
                            trends
                            records
                            bodyMetrics
                            healthConnection
                        }
                    }
                    if source == "Apple Health" && !health.hasConnected && pathSection != "Insights" {
                        healthConnection
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
                }.id(pathSection)
                .frame(maxHeight: .infinity)
                .refreshable {
                    if source == "Apple Health", health.hasConnected { await health.connect() }
                }
            }
                .pausePathSurface()
                .navigationTitle("My Path")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(PausePathPalette.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .task { await health.refreshIfConnected() }
                .onChange(of: pathScenePhase) { _, phase in if phase == .active { Task { await health.refreshIfConnected() } } }
                .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "PausePath-history") { result in
                    if case .failure = result { exportMessage = "Export could not be saved. Try again." }
                }
        }
    }
    private var sourceControls: some View {
        HStack(spacing: 12) {
            sourceMenu
            Spacer()
            if pathSection != "History" {
                Picker("Period", selection: $period) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }.pickerStyle(.menu).tint(PausePathPalette.teal)
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(PausePathPalette.teal.opacity(0.05), in: Capsule())
    }
    private var sourceMenu: some View {
        Picker("Activity source", selection: $source) {
            Text("PausePath").tag("PausePath")
            Text("Apple Health").tag("Apple Health")
        }.pickerStyle(.menu).tint(PausePathPalette.teal).onChange(of: source) { kind = "All" }
    }
    private var filteredHistory: [PathActivity] {
        guard historyDays > 0 else { return activities }
        let since = Calendar.current.date(byAdding: .day, value: -(historyDays - 1), to: Calendar.current.startOfDay(for: Date()))!
        return activities.filter { $0.date >= since && $0.date <= Date() }
    }
    private var historyCSV: String {
        func cell(_ value: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return "Date,Activity,Title,Distance_m,Active_seconds,Steps,Active_kcal\n" + filteredHistory.map { a in
            [ISO8601DateFormatter().string(from: a.date), a.kind, a.title, a.hasDistance ? String(a.meters) : "", String(a.seconds), a.steps.map { String($0) } ?? "", a.calories.map { String($0) } ?? ""].map(cell).joined(separator: ",")
        }.joined(separator: "\n")
    }
    private var personalGoal: some View {
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        let value = PersonalGoalProgress.total(metric: goalMetric, walks: walks, start: week.start, end: min(Date(), week.end))
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Weekly goal", systemImage: "flag.fill").font(.headline)
                Spacer()
                goalEditButton
            }
            ProgressView(value: min(value, goalTarget), total: goalTarget).tint(PausePathPalette.teal)
            HStack {
                Text("\(value, specifier: "%.1f") / \(goalTarget, specifier: "%.0f") \(goalUnit)")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                Spacer()
                if value >= goalTarget { Label("Done", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green) }
                else { Text("PausePath only").font(.caption).foregroundStyle(.secondary) }
            }
            if editingGoal {
                goalPicker
                Stepper(value: $goalTarget, in: goalRange, step: 1.0) {
                    Text("Goal: " + String(format: "%.0f", goalTarget) + " " + goalUnit)
                }
                Button("Remove weekly goal", role: .destructive) { goalEnabled = false; editingGoal = false }
                    .font(.caption)
            }
        }.pathCard()
    }
    private var goalEditButton: some View {
        Button(editingGoal ? "Done" : "Edit goal") { editingGoal.toggle() }
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
    }
    private var goalUnit: String { goalMetric == "distance" ? "km" : goalMetric }
    private var goalRange: ClosedRange<Double> {
        switch goalMetric {
        case "days": return 1.0...7.0
        case "minutes": return 1.0...600.0
        default: return 1.0...100.0
        }
    }
    private var goalPicker: some View {
        Menu {
            Picker("Measure", selection: $goalMetric) {
                Text("Distance (km)").tag("distance")
                Text("Minutes").tag("minutes")
                Text("Active days").tag("days")
            }
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(goalMetric == "distance" ? "Distance (km)" : (goalMetric == "minutes" ? "Minutes" : "Active days"))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.caption)
            }.frame(minHeight: 44)
        }.accessibilityLabel("Goal measure")
        .onChange(of: goalMetric) { _, metric in
            switch metric {
            case "days": goalTarget = 3.0
            case "minutes": goalTarget = 60.0
            default: goalTarget = 5.0
            }
        }
    }
    private var healthTotals: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Daily movement").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 140))], alignment: .leading, spacing: 16) {
                PathMetric(title: "Steps", value: optionalTotal(daily.compactMap(\.steps)), icon: "shoeprints.fill")
                PathMetric(title: "Active kcal", value: optionalTotal(daily.compactMap(\.calories)), icon: "flame")
            }
            Text("Health daily totals for this period include movement outside workouts. Not filtered by workout type. Missing readings are not treated as zero.")
                .font(.caption).foregroundStyle(.secondary)
        }.pathCard()
    }
    private func optionalTotal(_ values: [Double]) -> String {
        values.isEmpty ? "Not available" : values.reduce(0, +).formatted(.number.precision(.fractionLength(0)))
    }
    private var trends: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Your rhythm", systemImage: "chart.xyaxis.line").font(.headline)
            Chart {
                ForEach(0..<period, id: \.self) { index in
                    let day = Calendar.current.date(byAdding: .day, value: index - period + 1, to: Calendar.current.startOfDay(for: Date()))!
                    let distance = recent.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.meters } / 1000
                    BarMark(x: .value("Day", day, unit: .day), y: .value("Distance (km)", distance))
                        .foregroundStyle(PausePathPalette.teal.gradient).cornerRadius(3)
                }
            }.chartYAxisLabel("km").frame(height: 160)
                .accessibilityLabel("Daily distance for the last \(period) days")
            trendRow(days: 7, title: "Short term")
            Divider()
            trendRow(days: 30, title: "Long term")
            Text("Compares equal periods ending yesterday. All available \(source) activity types are included; history filters apply only to History.")
                .font(.caption).foregroundStyle(.secondary)
        }.pathCard()
    }
    @ViewBuilder private var walkingMinutesTrend: some View {
        if demoMode {
            VStack(spacing: 14) {
                sampleGrowthSummary
                walkingTrendCard(history: walkingHistory, isSample: true)
                walkingTrendCard(history: personalWalkingHistory, isSample: false)
            }
        } else {
            walkingTrendCard(history: personalWalkingHistory, isSample: false)
        }
    }

    private var sampleGrowthSummary: some View {
        let model = ActivityGrowthModel.illustrativeSample
        let endpoint = model.predictedMinutesPerDay(atWeek: model.horizonWeeks)
        return VStack(alignment: .leading, spacing: 10) {
            Label("Sample user · modeled scenario", systemImage: "sparkles")
                .font(.subheadline.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("12").font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Image(systemName: "arrow.right").font(.caption.bold()).foregroundStyle(.secondary)
                Text(endpoint, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text("min/day at week 8").font(.caption).foregroundStyle(.secondary)
            }
            Text("8-week modeled average: \(model.averageMinutesPerDay(), format: .number.precision(.fractionLength(1))) min/day · illustrative only, not a real user outcome")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("See the model") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("m(t) = b + A(1 − e⁻ᵏᵗ)")
                        .font(.system(.body, design: .serif).weight(.semibold))
                    Text("Sample inputs: b = 12 min/day, A = 10 min/day, k = 0.25/week, t = 8 weeks.")
                    Text("Average₀–₈ = 1/8 ∫₀⁸ m(t) dt = b + A[1 − (1 − e⁻⁸ᵏ)/(8k)]")
                    Text("The curve describes a fictional scenario; it does not show PausePath causing improvement.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
            .font(.caption.weight(.semibold))
        }
        .padding(15)
        .background(PausePathPalette.lime.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
    }

    private func walkingTrendCard(history: [WalkingHistoryEntry], isSample: Bool) -> some View {
        let summary = WalkingTrendSummary.calculate(history: history)
        return VStack(alignment: .leading, spacing: 14) {
            Label(isSample ? "Sample trend" : "Your recorded trend", systemImage: "chart.xyaxis.line").font(.headline)
            if isSample {
                Text("Synthetic weekly records generated from the sample model.")
                    .font(.caption.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
            } else {
                Text("PausePath walks + available Apple Health walking workouts. Overlaps count once; missing records don’t mean no walking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !summary.observedPoints.isEmpty {
                Chart {
                    ForEach(Array(summary.observedPoints.enumerated()), id: \.offset) { _, point in
                        PointMark(x: .value("Week", point.weekCoordinate + 1),
                                  y: .value("Recorded min/day", point.minutesPerDay))
                            .foregroundStyle(by: .value("Series", "Recorded weeks"))
                            .symbolSize(60)
                    }
                    if summary.status == .ready {
                        ForEach(Array(summary.curve.enumerated()), id: \.offset) { _, point in
                            LineMark(x: .value("Week", point.weekCoordinate + 1),
                                     y: .value("Fitted min/day", point.minutesPerDay))
                                .foregroundStyle(by: .value("Series", "Fitted trend"))
                                .lineStyle(StrokeStyle(lineWidth: 2.5))
                        }
                    }
                }.chartForegroundStyleScale(["Recorded weeks": PausePathPalette.teal, "Fitted trend": PausePathPalette.lime])
                    .chartYAxisLabel("min/day").frame(height: 190)
                    .accessibilityLabel("Recorded walking-workout minutes per day in observed weeks, with a fitted trend when enough weeks are available")
            }
            if let slope = summary.slopeMinutesPerDayPerWeek {
                Text(String(format: "Recent direction: %+.1f recorded min/day/week", slope))
                    .font(.subheadline.weight(.semibold))
            } else {
                Text("Not enough recorded history yet. A trend needs at least four observed weeks; unrecorded weeks stay unknown.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let baseline = summary.baselineAverage, let recent = summary.recentAverage {
                Text(String(format: "First 4 observed weeks: %.1f · last 4: %.1f min/day", baseline, recent))
                    .font(.subheadline)
                if let change = summary.percentChange {
                    Text(String(format: "Recent vs baseline: %+.1f%%", change)).font(.subheadline)
                }
            }
            if summary.totalObservedMinutes > 0 {
                Text(String(format: "%.0f total recorded minutes across observed weeks", summary.totalObservedMinutes))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !isSample {
                Text("No walking workouts recorded in this 8-week window; that does not mean no walking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let additional = summary.additionalMinutesOverBaseline {
                Text(String(format: "%+.0f minutes versus holding the first-four-week average for 56 days", additional))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("About this trend") {
                Text("Eight completed calendar weeks are shown. Dots are recorded sessions; the line estimates the trend between observed weeks. Weeks without a record are unknown, not zero. The direction is the fitted change at the latest observed week. Four observed weeks are needed to draw a line; comparisons need all eight.\(summary.limitation.map { " \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.caption.weight(.semibold))
            Text(isSample ? "Sample values are not measured results." : "This describes records over time, not an effect caused by PausePath or a measure of medical readiness.")
                .font(.caption).foregroundStyle(.secondary)
        }.pathCard()
    }
    private func trendRow(days: Int, title: String) -> some View {
        let records = activities.filter(\.hasDistance).map { TrackedWalk(date: $0.date, routeName: $0.title, distanceMeters: $0.meters, activeSeconds: $0.seconds, completed: true) }
        let totals = PathTrend.distance(walks: records, days: days)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(title) · \(days) days vs previous \(days)").font(.subheadline.weight(.semibold))
            Text("\(totals.current / 1000, specifier: "%.2f") km · previously \(totals.previous / 1000, specifier: "%.2f") km")
                .font(.subheadline)
            Text(totals.previous > 0 ? String(format: "%+.0f%% distance", (totals.current - totals.previous) / totals.previous * 100) : "No previous distance available for a percentage comparison")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Personal milestones", systemImage: "trophy.fill").font(.headline)
            Text("Completed PausePath journeys · saved on this device").font(.caption).foregroundStyle(.secondary)
            MilestoneTrail(badges: milestones.badges)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 140))], alignment: .leading, spacing: 16) {
                PathMetric(title: "Longest journey", value: String(format: "%.2f km", milestones.longest / 1000), icon: "map")
                PathMetric(title: "Longest active time", value: "\(Int(milestones.longestTime / 60)) min", icon: "timer")
            }
            if let pr = milestones.walks.last(where: { milestones.recordIDs.contains($0.id) }) {
                Label("Personal best! \(pr.routeName)", systemImage: "sparkles").font(.subheadline.bold())
                Text("\(pr.distanceMeters / 1000, specifier: "%.2f") km on \(pr.date.formatted(date: .abbreviated, time: .omitted)) — your longest journey yet.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Finish a journey to set your baseline. Go farther on a later journey to earn a distance PR.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NavigationLink { ScrollView { PathBadgeCollection(walks: walks).padding(20) }.pausePathSurface().navigationTitle("Path badges") } label: {
                Label("Explore all \(totalPathBadgeCount) badges", systemImage: "seal.fill").font(.subheadline.weight(.semibold))
            }
        }.pathCard()
    }
    @ViewBuilder private var bodyMetrics: some View {
        if !health.weight.isEmpty || !health.bodyFat.isEmpty || !health.height.isEmpty {
            DisclosureGroup("Body measurements") {
                if !health.weight.isEmpty { bodyRow("Weight", readings: health.weight, unit: "kg", multiplier: 1) }
                if !health.bodyFat.isEmpty { bodyRow("Body fat", readings: health.bodyFat, unit: "%", multiplier: 100) }
                if !health.height.isEmpty { bodyRow("Height", readings: health.height, unit: "cm", multiplier: 1) }
                Text("Health readings stay on this device and do not affect goals or badges.").font(.caption).foregroundStyle(.secondary)
            }.font(.headline).pathCard()
        }
    }
    private func bodyRow(_ title: String, readings: [BodyReading], unit: String, multiplier: Double) -> some View {
        NavigationLink {
            BodyTrendView(title: title, readings: readings, unit: unit, multiplier: multiplier)
        } label: {
            HStack {
                Text(title)
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(readings.first.map { String(format: "%.1f %@", $0.value * multiplier, unit) } ?? "Not shared")
                        .fontWeight(.semibold)
                    if let date = readings.first?.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                }
                Image(systemName: "chevron.right").font(.caption)
            }
        }.buttonStyle(.plain)
    }
    private var historyFilter: some View {
        Menu {
                        Picker("Activity", selection: $kind) {
                            Text("All activities").tag("All")
                            ForEach(Array(Set((source == "Apple Health" ? health.activities.map(\.kind) : walks.map { $0.activityKind ?? "Walking" }))).sorted(), id: \.self) { Text($0).tag($0) }
                        }
                    } label: { Label(kind, systemImage: "line.3.horizontal.decrease") }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("Workout history").font(.title3.bold()); Spacer(); historyFilter }
                VStack(alignment: .leading, spacing: 8) { Text("Workout history").font(.title3.bold()); historyFilter }
            }
            Picker("History dates", selection: $historyDays) {
                Text("All dates").tag(0); Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
            }.pickerStyle(.menu)
            Button("Export filtered history (CSV)", systemImage: "square.and.arrow.up") {
                exportDocument = PathExportDocument(text: historyCSV); exporting = true
            }.disabled(filteredHistory.isEmpty)
            if source == "Apple Health", !hiddenHealthData.isEmpty {
                Button("Restore hidden Health workouts") { hiddenHealthData = Data() }
            }
            if !exportMessage.isEmpty { Text(exportMessage).font(.caption) }
            Text("Available \(source) sessions · newest first").font(.caption).foregroundStyle(.secondary)
            if filteredHistory.isEmpty { ContentUnavailableView("No sessions in this selection", systemImage: "figure.walk", description: Text("Track a route in Explore, or connect Apple Health for workout history.")) }
            LazyVStack(spacing: 12) {
                ForEach(filteredHistory) { activity in
                    NavigationLink { PathJourneyDetail(activity: activity, health: health) } label: {
                        activityRow(activity).pathCard()
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func activityRow(_ activity: PathActivity) -> some View {
        HStack(spacing: 14) {
            Image(systemName: activity.symbol).font(.title2).foregroundStyle(PausePathPalette.teal)
                .frame(width: 48, height: 48).background(PausePathPalette.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 5) {
                Text(activity.title).font(.headline)
                Text(activity.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text("\(activity.hasDistance ? String(format: "%.2f km", activity.meters / 1000) : "Distance not recorded") · \(Int(activity.seconds / 60)) min").font(.subheadline)
                if let walk = activity.tracked {
                    if !walk.completed { Text("Ended early").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var healthConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Connect the full picture", systemImage: "heart").font(.headline)
            Text(health.status).font(.caption).foregroundStyle(.secondary)
            Button { Task { await health.connect() } } label: {
                HStack { if health.isLoading { ProgressView() }; Text(health.isLoading ? "Reading Health…" : "Connect / refresh Apple Health") }
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(health.isLoading)
            DisclosureGroup("About Health data", isExpanded: $showHealthExplanation) {
                Text("You choose which readings to share. Missing readings stay unknown. Health readings and journey maps stay on this device.").font(.caption).foregroundStyle(.secondary)
            }.font(.caption)
            if health.hasConnected { Button("Clear Health session", role: .destructive) { health.clear() }.font(.caption) }
        }.pathCard()
    }
}

private struct PathMetric: View {
    let title: String
    let value: String
    let icon: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption)
            Text(value).font(.system(.title3, design: .rounded).bold()).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func pathCard() -> some View {
        self.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: PausePathPalette.corner))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(PausePathPalette.teal.opacity(0.12), lineWidth: 1))
    }
}

private struct JourneyMap: View {
    let segments: [[CLLocationCoordinate2D]]
    var body: some View {
        Map {
            ForEach(segments.indices, id: \.self) { index in
                MapPolyline(coordinates: segments[index]).stroke(PausePathPalette.teal, lineWidth: 5)
            }
            if let start = segments.first?.first { Marker("Start", systemImage: "circle.fill", coordinate: start).tint(PausePathPalette.teal) }
            if let end = segments.last?.last { Marker("Finish", systemImage: "flag.fill", coordinate: end).tint(PausePathPalette.teal) }
        }.mapControls { MapCompass(); MapScaleView() }
    }
}

private struct PathJourneyDetail: View {
    let activity: PathActivity
    let health: HealthActivityStore
    @State private var segments: [[CLLocationCoordinate2D]] = []
    @State private var loading = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var mapMessage = "No GPS journey was saved for this session."
    @State private var intervalSteps: Double?
    @State private var intervalCalories: Double?
    @State private var intervalHeartRate: Double?
    @State private var metricError: String?
    @AppStorage("pausepath.trackedWalks") private var detailWalkData = Data()
    @AppStorage("pausepath.hiddenHealthWorkouts") private var detailHiddenData = Data()
    @Environment(\.dismiss) private var detailDismiss
    @State private var confirmDelete = false
    @State private var exportingRoute = false
    @State private var routeExport = PathExportDocument(text: "")
    private var steps: Double? { activity.steps ?? intervalSteps }
    private var calories: Double? { activity.calories ?? intervalCalories }
    private var heartRate: Double? { activity.heartRate ?? intervalHeartRate }
    private var fullSummary: String {
        var text = activity.summary
        if let steps { text += String(format: " Recorded steps: %.0f.", steps) }
        if let calories { text += String(format: " Active energy: %.0f kcal.", calories) }
        if let heartRate { text += String(format: " Average heart rate: %.0f bpm.", heartRate) }
        if intervalSteps != nil || intervalCalories != nil || intervalHeartRate != nil {
            text += " Health readings cover the journey interval, including pauses."
        }
        return text
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(activity.kind, systemImage: activity.symbol).font(.title2.bold()).foregroundStyle(PausePathPalette.teal)
                Text(activity.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                if !segments.isEmpty {
                    JourneyMap(segments: segments).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 24))
                    Text("Recorded GPS journey. Gaps mark pauses or unavailable tracking; GPS accuracy can vary.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(loading ? "Loading journey…" : "Journey map unavailable", systemImage: "map",
                        description: Text(loading ? "Reading the route shared through Health." : mapMessage))
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your session, summarized").font(.headline)
                    Text(fullSummary)
                    ShareLink(item: fullSummary) { Label("Share summary", systemImage: "square.and.arrow.up") }
                }.pathCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 140))], spacing: 24) {
                    PathMetric(title: "Distance", value: activity.hasDistance ? String(format: "%.2f km", activity.meters / 1000) : "Not recorded", icon: "map")
                    PathMetric(title: "Active time", value: "\(Int(activity.seconds / 60)) min", icon: "clock")
                    PathMetric(title: "Average pace", value: activity.pace, icon: "speedometer")
                    PathMetric(title: "Steps", value: steps.map { String(format: "%.0f", $0) } ?? "Not recorded", icon: "shoeprints.fill")
                    PathMetric(title: "Active calories", value: calories.map { String(format: "%.0f kcal", $0) } ?? "Not recorded", icon: "flame")
                    PathMetric(title: "Average heart rate", value: heartRate.map { String(format: "%.0f bpm", $0) } ?? "Not recorded", icon: "heart")
                }.pathCard()
                if let walk = activity.tracked {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Journey timeline").font(.headline)
                        if let start = walk.startedAt { Label("Started \(start.formatted(date: .omitted, time: .shortened))", systemImage: "circle") }
                        Label("\(Int(walk.activeSeconds / 60)) active minutes", systemImage: "figure.walk")
                        if let count = walk.journeySegments?.count, count > 1 { Label("\(count) recorded sections", systemImage: "pause.circle") }
                        Label("\(walk.completed ? "Completed" : "Ended early") \(walk.date.formatted(date: .omitted, time: .shortened))", systemImage: "flag")
                    }.pathCard()
                }
                Text(activity.isHealth ? "Source: Apple Health. Metrics are shown only when recorded with this workout." :
                    "Source: PausePath GPS and motion tracking. Distance counts progress along the navigation route, including earlier sections before recalculation. If connected, Health fills available readings during the journey’s start/end interval, including pauses. Values are never estimated from distance.")
                    .font(.caption).foregroundStyle(.secondary)
                JourneyNotesView(activityID: activity.id)
                if !segments.isEmpty {
                    Button("Export journey (GPX)", systemImage: "square.and.arrow.up") {
                        let tracks = segments.map { segment in
                            "<trkseg>" + segment.map { "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"/>" }.joined() + "</trkseg>"
                        }.joined()
                        routeExport = PathExportDocument(text: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"PausePath\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk>" + tracks + "</trk></gpx>")
                        exportingRoute = true
                    }
                }
                Button(activity.isHealth ? "Hide this workout from PausePath" : "Delete this journey", role: .destructive) { confirmDelete = true }
                if let metricError { Text(metricError).font(.caption).foregroundStyle(.secondary) }
                if !health.hasConnected {
                    Text("Connect Apple Health in My Path for available calories and heart-rate readings.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.pausePathSurface().navigationTitle(activity.title).navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exportingRoute, document: routeExport, contentType: UTType(filenameExtension: "gpx") ?? .xml, defaultFilename: "PausePath-journey.gpx") { result in
                if case .failure = result { metricError = "Could not export this journey." }
            }
            .alert(activity.isHealth ? "Hide this workout?" : "Delete this journey?", isPresented: $confirmDelete) {
                Button("Cancel", role: .cancel) { }
                Button(activity.isHealth ? "Hide" : "Delete", role: .destructive) {
                    if activity.isHealth {
                        var hidden = (try? JSONDecoder().decode(Set<String>.self, from: detailHiddenData)) ?? []
                        hidden.insert(activity.id); detailHiddenData = (try? JSONEncoder().encode(hidden)) ?? detailHiddenData
                    } else {
                        var walks = (try? JSONDecoder().decode([TrackedWalk].self, from: detailWalkData)) ?? []
                        walks.removeAll { $0.id.uuidString == activity.id }
                        detailWalkData = (try? JSONEncoder().encode(walks)) ?? detailWalkData
                        NotificationCenter.default.post(name: .pausePathWalkRecorded, object: nil)
                        Task { try? await PausePathAPI.syncChallengeProgress(walks: walks) }
                    }
                    detailDismiss()
                }
            } message: {
                Text(activity.isHealth ? "The original stays in Apple Health. Restore hidden workouts from history." : "This removes the saved map and changes your totals and personal records. Already-earned badges remain earned.")
            }
            .task(id: activity.id) {
                if let walk = activity.tracked {
                    segments = (walk.journeySegments ?? []).map { $0.map(\.mapCoordinate) }
                    if let start = walk.startedAt, health.hasConnected {
                        do {
                            let values = try await health.journeyMetrics(from: start, to: walk.date)
                            intervalSteps = values.steps; intervalCalories = values.calories; intervalHeartRate = values.heartRate
                        } catch { metricError = "Health readings could not be loaded for this interval." }
                    }
                } else {
                    loading = true
                    defer { loading = false }
                    do { segments = try await health.route(for: activity.id) }
                    catch { mapMessage = "The route couldn’t be loaded. Return and try again." }
                }
            }
    }
}

private struct BodyTrendView: View {
    let title: String
    let readings: [BodyReading]
    let unit: String
    let multiplier: Double
    @State private var days = 30
    private var visible: [BodyReading] {
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
        return readings.filter { $0.date >= start }.sorted { $0.date < $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Trend period", selection: $days) {
                    Text("30 days").tag(30); Text("90 days").tag(90); Text("1 year").tag(365)
                }.pickerStyle(.segmented)
                if visible.isEmpty {
                    ContentUnavailableView("No shared readings", systemImage: "heart", description: Text("Add measurements in Apple Health and choose to share them with PausePath, then refresh Health in My Path."))
                } else {
                    Chart(visible) { reading in
                        LineMark(x: .value("Date", reading.date), y: .value(title, reading.value * multiplier)).foregroundStyle(PausePathPalette.teal)
                        PointMark(x: .value("Date", reading.date), y: .value(title, reading.value * multiplier)).foregroundStyle(PausePathPalette.teal)
                    }.chartYAxisLabel(unit).frame(height: 230)
                    if let first = visible.first, let last = visible.last, visible.count > 1 {
                        Text(String(format: "Change across available readings: %+.1f %@", (last.value - first.value) * multiplier, unit)).font(.headline)
                    }
                    Text("Actual measurement dates; gaps are not daily measurements. Changes are shown without a good/bad rating.").font(.caption).foregroundStyle(.secondary)
                    ForEach(visible.reversed()) { reading in
                        HStack {
                            Text(reading.date.formatted(date: .abbreviated, time: .omitted))
                            Spacer()
                            Text(String(format: "%.1f %@", reading.value * multiplier, unit)).bold()
                        }.pathCard()
                    }
                }
            }.padding(20)
        }.pausePathSurface().navigationTitle(title)
    }
}

private struct PathBadgeArtStyle {
    let primary: Color
    let highlight: Color
    let flourish: String

    static func forID(_ id: String) -> PathBadgeArtStyle {
        switch id {
        case "welcome": PathBadgeArtStyle(primary: Color(red: 0.02, green: 0.42, blue: 0.47), highlight: Color(red: 0.35, green: 0.84, blue: 0.72), flourish: "sparkles")
        case "walks-1": PathBadgeArtStyle(primary: Color(red: 0.16, green: 0.55, blue: 0.35), highlight: Color(red: 0.63, green: 0.88, blue: 0.40), flourish: "leaf.fill")
        case "walks-5": PathBadgeArtStyle(primary: Color(red: 0.04, green: 0.53, blue: 0.63), highlight: Color(red: 0.42, green: 0.84, blue: 0.87), flourish: "wind")
        case "walks-10": PathBadgeArtStyle(primary: Color(red: 0.77, green: 0.42, blue: 0.12), highlight: Color(red: 1.00, green: 0.78, blue: 0.30), flourish: "sun.max.fill")
        case "walks-25": PathBadgeArtStyle(primary: Color(red: 0.13, green: 0.43, blue: 0.31), highlight: Color(red: 0.54, green: 0.78, blue: 0.36), flourish: "map.fill")
        case "distance-1": PathBadgeArtStyle(primary: Color(red: 0.10, green: 0.50, blue: 0.76), highlight: Color(red: 0.46, green: 0.82, blue: 0.95), flourish: "location.fill")
        case "distance-5": PathBadgeArtStyle(primary: Color(red: 0.00, green: 0.55, blue: 0.54), highlight: Color(red: 0.37, green: 0.85, blue: 0.71), flourish: "point.topleft.down.to.point.bottomright.curvepath")
        case "distance-10": PathBadgeArtStyle(primary: Color(red: 0.19, green: 0.38, blue: 0.79), highlight: Color(red: 0.47, green: 0.69, blue: 0.98), flourish: "map.fill")
        case "distance-25": PathBadgeArtStyle(primary: Color(red: 0.46, green: 0.29, blue: 0.72), highlight: Color(red: 0.76, green: 0.57, blue: 0.91), flourish: "signpost.right.fill")
        case "distance-50": PathBadgeArtStyle(primary: Color(red: 0.86, green: 0.37, blue: 0.16), highlight: Color(red: 1.00, green: 0.69, blue: 0.34), flourish: "sun.horizon.fill")
        case "distance-100": PathBadgeArtStyle(primary: Color(red: 0.73, green: 0.48, blue: 0.08), highlight: Color(red: 1.00, green: 0.83, blue: 0.33), flourish: "sparkles")
        case "longest-3": PathBadgeArtStyle(primary: Color(red: 0.22, green: 0.55, blue: 0.34), highlight: Color(red: 0.71, green: 0.88, blue: 0.38), flourish: "leaf.fill")
        case "longest-5": PathBadgeArtStyle(primary: Color(red: 0.78, green: 0.29, blue: 0.23), highlight: Color(red: 1.00, green: 0.64, blue: 0.34), flourish: "flag.checkered")
        case "minutes-30": PathBadgeArtStyle(primary: Color(red: 0.06, green: 0.48, blue: 0.56), highlight: Color(red: 0.36, green: 0.80, blue: 0.73), flourish: "clock.fill")
        case "minutes-60": PathBadgeArtStyle(primary: Color(red: 0.77, green: 0.46, blue: 0.08), highlight: Color(red: 1.00, green: 0.79, blue: 0.33), flourish: "sun.max.fill")
        case "days-3": PathBadgeArtStyle(primary: Color(red: 0.31, green: 0.55, blue: 0.26), highlight: Color(red: 0.73, green: 0.88, blue: 0.40), flourish: "calendar")
        case "days-7": PathBadgeArtStyle(primary: Color(red: 0.04, green: 0.48, blue: 0.41), highlight: Color(red: 0.40, green: 0.82, blue: 0.64), flourish: "calendar.badge.checkmark")
        case "pr-1": PathBadgeArtStyle(primary: Color(red: 0.58, green: 0.34, blue: 0.19), highlight: Color(red: 0.89, green: 0.65, blue: 0.34), flourish: "trophy.fill")
        case "pr-5": PathBadgeArtStyle(primary: Color(red: 0.63, green: 0.43, blue: 0.10), highlight: Color(red: 1.00, green: 0.85, blue: 0.43), flourish: "rosette")
        default: PathBadgeArtStyle(primary: PausePathPalette.teal, highlight: PausePathPalette.lime, flourish: "sparkles")
        }
    }
}

private struct PathBadgeMedallion: View {
    let badge: PathBadge
    let isEarned: Bool
    let size: CGFloat

    private var style: PathBadgeArtStyle { PathBadgeArtStyle.forID(badge.id) }
    private var fill: LinearGradient {
        let colors = isEarned ? [style.highlight, style.primary] : [Color.gray.opacity(0.14), Color.gray.opacity(0.25)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle()
                .strokeBorder(isEarned ? Color.white.opacity(0.86) : Color.gray.opacity(0.22), lineWidth: max(1, size * 0.035))
                .padding(size * 0.10)
            Circle()
                .strokeBorder(isEarned ? style.highlight.opacity(0.8) : Color.gray.opacity(0.16), lineWidth: max(1, size * 0.025))
                .padding(size * 0.20)
            Image(systemName: badge.symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(isEarned ? Color.white : Color.gray.opacity(0.64))
            if isEarned {
                Image(systemName: style.flourish)
                    .font(.system(size: size * 0.17, weight: .bold))
                    .foregroundStyle(Color.white)
                    .offset(x: size * 0.29, y: -size * 0.28)
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: isEarned ? "checkmark.circle.fill" : "lock.circle.fill")
                .font(.system(size: size * 0.27))
                .symbolRenderingMode(.palette)
                .foregroundStyle(isEarned ? style.primary : Color.gray.opacity(0.72), PausePathPalette.surface)
                .offset(x: size * 0.06, y: size * 0.05)
        }
        .accessibilityHidden(true)
    }
}

struct PathBadgeCollection: View {
    private var welcomeBadge: PathBadge {
        PathBadge(
            id: "welcome", name: "Welcome to PausePath", symbol: "hand.wave.fill",
            requirement: "Welcome to PausePath. This badge is yours from day one.",
            value: 1, target: 1
        )
    }

    let walks: [TrackedWalk]
    @AppStorage("pausepath.earnedBadges.v1") private var earnedData = Data()
    @State private var selected: PathBadge?
    private var saved: [String: Date] { (try? JSONDecoder().decode([String: Date].self, from: earnedData)) ?? [:] }
    private var badges: [PathBadge] { [welcomeBadge] + PathMilestones(walks: walks).badges }
    private func earned(_ badge: PathBadge) -> Bool { badge.earned || saved[badge.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Your path badges", systemImage: "seal.fill").font(.title3.bold())
                Spacer()
                Text("\(badges.filter { earned($0) }.count) / \(badges.count)").font(.subheadline.monospacedDigit())
            }.foregroundStyle(PausePathPalette.teal)
            Text("A welcome keepsake plus milestones from your completed PausePath journeys. Locked badges stay muted until you earn them.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 94))], spacing: 18) {
                ForEach(badges) { badge in badgeCard(badge) }
            }
        }
        .onAppear { saveEarned() }
        .onChange(of: walks.map(\.id)) { saveEarned() }
        .sheet(item: $selected) { badge in
            let isEarned = earned(badge)
            let style = PathBadgeArtStyle.forID(badge.id)
            NavigationStack {
                VStack(spacing: 18) {
                    PathBadgeMedallion(badge: badge, isEarned: isEarned, size: 112)
                    Text(badge.name).font(.title2.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(isEarned ? style.primary : Color.primary)
                    Text(isEarned ? "Earned" : "Locked")
                        .font(.headline).foregroundStyle(isEarned ? style.primary : Color.secondary)
                    Text(badge.requirement).multilineTextAlignment(.center)
                    if !isEarned {
                        ProgressView(value: badge.fraction).tint(Color.gray.opacity(0.55))
                        Text("\(min(badge.value, badge.target), specifier: "%.1f") of \(badge.target, specifier: "%.0f")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).pausePathSurface()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { selected = nil } }
                }
            }.presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func badgeCard(_ badge: PathBadge) -> some View {
        let isEarned = earned(badge)
        let style = PathBadgeArtStyle.forID(badge.id)
        Button { selected = badge } label: {
            VStack(spacing: 9) {
                PathBadgeMedallion(badge: badge, isEarned: isEarned, size: 66)
                Text(badge.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                    .foregroundStyle(isEarned ? style.primary : Color.primary).frame(minHeight: 34)
                if isEarned {
                    Text("Earned").font(.caption2.weight(.bold)).foregroundStyle(style.primary)
                } else {
                    ProgressView(value: badge.fraction).tint(Color.gray.opacity(0.55))
                }
            }
            .padding(10).frame(maxWidth: .infinity)
            .background(isEarned ? style.primary.opacity(0.09) : Color.gray.opacity(0.035), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(isEarned ? style.primary.opacity(0.28) : Color.gray.opacity(0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(badge.name), \(isEarned ? "earned" : "locked"). \(badge.requirement)")
    }

    private func saveEarned() {
        var result = saved
        for badge in badges where badge.earned && result[badge.id] == nil { result[badge.id] = Date() }
        if result.count != saved.count { earnedData = (try? JSONEncoder().encode(result)) ?? earnedData }
    }
}

private struct PathExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText, .xml] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
private struct JourneyNote: Codable { var feeling: String; var text: String }
private struct JourneyNotesView: View {
    let activityID: String
    @AppStorage("pausepath.journeyNotes") private var noteData = Data()
    @State private var feeling = "Not set"
    @State private var text = ""
    @State private var saved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your reflections", systemImage: "square.and.pencil").font(.headline)
            Picker("How did it feel?", selection: $feeling) {
                ForEach(["Not set", "Easy", "Comfortable", "Challenging", "Tough"], id: \.self) { Text($0).tag($0) }
            }
            TextField("A note for your future self…", text: $text, axis: .vertical).lineLimit(3...6)
                .onChange(of: text) { saved = false }
            Button(saved ? "Saved on this device" : "Save note") {
                var notes = (try? JSONDecoder().decode([String: JourneyNote].self, from: noteData)) ?? [:]
                notes[activityID] = JourneyNote(feeling: feeling, text: text)
                if let data = try? JSONEncoder().encode(notes) { noteData = data; saved = true }
            }.disabled(text.count > 2000)
            Text("Private · not included in community posts or exports. Up to 2,000 characters.").font(.caption).foregroundStyle(.secondary)
        }.pathCard().onAppear {
            if let note = (try? JSONDecoder().decode([String: JourneyNote].self, from: noteData))?[activityID] { feeling = note.feeling; text = note.text }
        }.onChange(of: feeling) { saved = false }
    }
}

/// Shared tab strip keeps each page focused without adding another navigation stack.
struct PathSectionPicker: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let titles: [String]
    @Binding var selection: String
    var usesMaterialBackground = true
    var body: some View {
        Group {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("Section", selection: $selection) {
                ForEach(titles, id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.menu).tint(PausePathPalette.teal)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
        } else {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(titles, id: \.self) { title in
                    Button { selection = title } label: {
                        Text(title).font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18).frame(minHeight: 44)
                            .foregroundStyle(selection == title ? PausePathPalette.ink : PausePathPalette.teal)
                            .background(selection == title ? PausePathPalette.lime : Color.clear, in: Capsule())
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(selection == title ? [.isSelected] : [])
                }
            }.padding(6)
                .background(PausePathPalette.teal.opacity(0.06), in: Capsule())
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        }
        }.background {
            if usesMaterialBackground { Rectangle().fill(.regularMaterial) }
            else { Rectangle().fill(PausePathPalette.background) }
        }
        // In a vertical stack, a horizontal ScrollView can otherwise accept surplus
        // height and appear as a large empty panel above the page content.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Decorative contour artwork; never represents a real route or terrain data.
struct AdventureContours: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<8 {
            let inset = CGFloat(index) * 18
            let box = CGRect(x: rect.width * 0.52 - inset, y: -50 - inset * 0.3,
                             width: rect.width * 0.65 + inset * 2, height: rect.height + 70 + inset)
            path.addRoundedRect(in: box, cornerSize: CGSize(width: box.width * 0.38, height: box.height * 0.4))
        }
        return path
    }
}
struct AdventureHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var symbol = "mountain.2.fill"
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(eyebrow).font(.caption2.weight(.bold)).tracking(2)
                Spacer(minLength: 8)
                Image(systemName: symbol).font(.title2).foregroundStyle(PausePathPalette.lime).accessibilityHidden(true)
            }.foregroundStyle(Color.white.opacity(0.8))
            Text(title).font(.system(.title2, design: .rounded).bold()).foregroundStyle(.white)
            if !typeSize.isAccessibilitySize {
                Text(subtitle).font(.subheadline).foregroundStyle(Color.white.opacity(0.85))
            }
            HStack(spacing: 5) {
                Circle().fill(PausePathPalette.lime).frame(width: 7, height: 7)
                Capsule().fill(PausePathPalette.lime.opacity(0.6)).frame(width: 38, height: 2)
                Image(systemName: "location.north.fill").font(.caption2).foregroundStyle(PausePathPalette.lime)
            }.accessibilityHidden(true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.025, green: 0.23, blue: 0.22))
            .background { AdventureContours().stroke(Color.white.opacity(0.09), lineWidth: 1) }
            .overlay(alignment: .trailing) {
                AdventureContours().stroke(Color.white.opacity(0.07), lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
struct TrailEmblem: View {
    let seed: String
    private var symbol: String {
        let icons = ["mountain.2.fill", "leaf.fill", "water.waves", "sun.horizon.fill"]
        return icons[seed.utf8.reduce(0) { ($0 + Int($1)) % icons.count }]
    }
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
            .frame(width: 50, height: 56)
            .background(Color(red: 0.88, green: 0.84, blue: 0.70), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).inset(by: 4).stroke(PausePathPalette.teal.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .accessibilityHidden(true)
    }
}
private struct MilestoneTrail: View {
    let badges: [PathBadge]
    @AppStorage("pausepath.earnedBadges.v1") private var earnedData = Data()
    private var saved: [String: Date] { (try? JSONDecoder().decode([String: Date].self, from: earnedData)) ?? [:] }
    private var stops: [PathBadge] { badges.filter { ["walks-1", "distance-5", "distance-25", "distance-100"].contains($0.id) } }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, badge in
                let earned = badge.earned || saved[badge.id] != nil
                HStack(spacing: 14) {
                    Image(systemName: earned ? badge.symbol : "flag")
                        .font(.headline).foregroundStyle(earned ? PausePathPalette.ink : PausePathPalette.teal)
                        .frame(width: 44, height: 44)
                        .background(earned ? PausePathPalette.lime : Color.secondary.opacity(0.1), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(badge.name).font(.subheadline.bold())
                        Text(earned ? "Milestone reached" : badge.requirement).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if earned { Image(systemName: "checkmark.seal.fill").foregroundStyle(PausePathPalette.teal) }
                }.padding(.leading, index.isMultiple(of: 2) ? 0 : 24)
                    .accessibilityElement(children: .combine)
                if index < stops.count - 1 {
                    TrailBend(reverse: !index.isMultiple(of: 2))
                        .stroke(PausePathPalette.teal.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))
                        .frame(width: 68, height: 28).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                }
            }
        }.padding(.vertical, 8)
    }
}
private struct TrailBend: Shape {
    let reverse: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start: CGFloat = reverse ? 46 : 22
        let end: CGFloat = reverse ? 22 : 46
        path.move(to: CGPoint(x: start, y: 0))
        path.addCurve(to: CGPoint(x: end, y: rect.height), control1: CGPoint(x: start, y: rect.height * 0.6), control2: CGPoint(x: end, y: rect.height * 0.4))
        return path
    }
}
