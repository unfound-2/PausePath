import SwiftUI
import PhotosUI
import MapKit
import UserNotifications

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
        content.body = "See your walking summary in My progress whenever it suits you."
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
    let health: HealthActivityStore
    var body: some View {
        TabView(selection: $selectedTab) {
            DiscoverView(preferences: preferences, profile: profile).tabItem { Label("Explore", systemImage: "map.fill") }.tag(0)
            CommunityChallengesView(preferences: preferences).tabItem { Label("Community", systemImage: "person.3.fill") }.tag(1)
            ReviewView(preferences: $preferences, health: health).tabItem { Label("My progress", systemImage: "chart.bar.fill") }.tag(2)
            ProfileSettingsView(preferences: $preferences, health: health).tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(3)
        }.tint(PausePathPalette.teal)
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
                            Text("Your pace. Your path.").font(.subheadline).foregroundStyle(.secondary)
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
                        Text(weeklyWalks.isEmpty ? "A little fresh air is a good place to start. Your tracked walks will appear here." : "Time outside, at your own pace. Keep your goals flexible.")
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
                    section("Account & privacy") {
                        NavigationLink { AccountView() } label: {
                            row("Account settings", detail: account.isSignedIn ? account.sessionStatusText : "Sign in to join your community", icon: "person.crop.circle")
                        }
                        Divider().padding(.leading, 60)
                        NavigationLink { privacySettings } label: {
                            row("Privacy & credits", detail: "Your data, your choices", icon: "hand.raised")
                        }
                    }
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
            VStack(spacing: 0, content: content).background(.background, in: RoundedRectangle(cornerRadius: 22))
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
    private var healthSettings: some View {
        Form {
            Section { Text(health.status); Button(health.isLoading ? "Reading…" : "Connect / refresh Health") { Task { await health.connect() } }.disabled(health.isLoading) }
            Section { Text("Health activity stays on this device and is shown separately from PausePath-tracked walks to avoid double counting."); Button("Clear session data", role: .destructive) { health.clear() } }
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
            Section { Text("Location helps find nearby stops and guide your walk. Live tracking runs during an active walk while PausePath is open."); Button("Open iOS Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) } }
        }.pausePathSurface().navigationTitle("Location")
    }
    private var privacySettings: some View {
        Form {
            Section("Your profile") { Text("Your photo stays on this device. Your username is visible to communities you join; a nickname is welcome.") }
            Section("Your activity") { Text("Health data and tracked walks stay on this device. Community progress is shared only when you submit it. Route planning and nearby searches send the relevant map area or planned route to our services.") }
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
                    Text("A walk at your pace").font(.title2.bold())
                    Text("Choose what matters today. You control every adjustment.").foregroundStyle(.secondary)
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
                    } else { Text("Manual estimate. Optional Health walking speed can be connected in My progress.").font(.caption) }
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

struct ReviewView: View {
    @Binding var preferences: RoutePreferences
    var health: HealthActivityStore
    @AppStorage("pausepath.personalProfile") private var profileData = Data()
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }
    private var trackedWalks: [TrackedWalk] { (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? [] }
    private var todayTrackedWalks: [TrackedWalk] { trackedWalks.filter { Calendar.current.isDateInToday($0.date) } }
    private var todayActivities: [WalkingActivity] { health.activities.filter { Calendar.current.isDateInToday($0.date) } }
    private var todayMinutes: Int { Int(todayActivities.reduce(0) { $0 + $1.seconds } / 60) }
    private var todayDistance: Double { todayActivities.reduce(0) { $0 + $1.meters } / 1000 }
    private var weekActivities: [WalkingActivity] {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        return health.activities.filter { interval.contains($0.date) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Optional Apple Health") {
                    Text(health.status).font(.callout)
                    Button(health.isLoading ? "Reading…" : "Connect / refresh Health") { Task { await health.connect() } }.disabled(health.isLoading)
                    Text("Reads walking workouts, walking speed and recorded workout heart rate when available. Nothing is written to Health or sent to a server.").font(.caption).foregroundStyle(.secondary)
                    Button("Clear Health data from this session") { health.clear() }
                }
                Section("Today’s recap") {
                    if todayActivities.isEmpty {
                        Text(health.activities.isEmpty
                             ? "No Health walks are available today. You can still track a route walk with PausePath."
                             : "No walking workouts are recorded for today. Rest days count too; choose what feels right for you.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You recorded \(todayActivities.count) walk\(todayActivities.count == 1 ? "" : "s") today.")
                            .font(.headline)
                        Text("\(todayDistance, specifier: "%.1f") km • \(todayMinutes) minutes")
                        Text("Your weekly goal is \(profile.weeklyMinutesTarget) minutes across \(profile.weeklyWalkTarget) walks. Every week can look different.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let heartRate = todayActivities.compactMap(\.averageHeartRate).first {
                            Text("Health recorded an average heart rate of \(Int(heartRate)) bpm during a walk. This is shown for context only and does not determine your route or goal.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !todayTrackedWalks.isEmpty {
                        let minutes = Int(todayTrackedWalks.reduce(0) { $0 + $1.activeSeconds } / 60)
                        let distance = todayTrackedWalks.reduce(0) { $0 + $1.distanceMeters } / 1000
                        Text("PausePath tracked \(todayTrackedWalks.count) walk\(todayTrackedWalks.count == 1 ? "" : "s"): \(distance, specifier: "%.1f") km and \(minutes) active minutes.")
                        Text("Your route-tracked walks contribute toward your chosen weekly goal and stay on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("This is an activity summary, not medical advice or a measure of recovery. Progress may be incomplete if Health access is off or workouts weren’t recorded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("This week") {
                    let minutes = Int(weekActivities.reduce(0) { $0 + $1.seconds } / 60)
                    let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
                    let tracked = trackedWalks.filter { interval.contains($0.date) }
                    let trackedMinutes = Int(tracked.reduce(0) { $0 + $1.activeSeconds } / 60)
                    ProgressView(value: min(Double(minutes), Double(profile.weeklyMinutesTarget)), total: Double(profile.weeklyMinutesTarget))
                    ProgressView(value: min(Double(weekActivities.count), Double(profile.weeklyWalkTarget)), total: Double(profile.weeklyWalkTarget))
                    Text("Health: \(weekActivities.count) / \(profile.weeklyWalkTarget) walks • \(minutes) / \(profile.weeklyMinutesTarget) minutes")
                    ProgressView(value: min(Double(tracked.count), Double(profile.weeklyWalkTarget)), total: Double(profile.weeklyWalkTarget))
                    ProgressView(value: min(Double(trackedMinutes), Double(profile.weeklyMinutesTarget)), total: Double(profile.weeklyMinutesTarget))
                    Text("PausePath tracked: \(tracked.count) / \(profile.weeklyWalkTarget) walks • \(trackedMinutes) / \(profile.weeklyMinutesTarget) active minutes")
                    Text("Progress may be incomplete when activities are unavailable or not shared.").font(.caption)
                }
                Section("Recent walking activities") {
                    if health.activities.isEmpty { Text("No available walking activities.").foregroundStyle(.secondary) }
                    ForEach(health.activities) { activity in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(activity.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(activity.meters / 1000, specifier: "%.2f") km • \(Int(activity.seconds / 60)) min • \(activity.pace)")
                            Text(activity.averageHeartRate.map { "Recorded average heart rate: \(Int($0)) bpm" } ?? "Recorded heart rate unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.pausePathSurface()
        .navigationTitle("My progress")
        }
    }
}
