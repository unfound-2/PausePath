import SwiftUI
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
        }.tint(Color(red: 0.12, green: 0.40, blue: 0.32))
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
    private var profile: PausePathProfile { (try? JSONDecoder().decode(PausePathProfile.self, from: profileData)) ?? PausePathProfile() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Welcome, \(profile.username ?? "Walker")").font(.title2.bold())
                    Text("Your profile and walking choices are yours to update.").foregroundStyle(.secondary)
                }
                Section("Profile") {
                    NavigationLink("Change Username") { ChangeUsernameView() }
                    if let username = profile.username, !username.isEmpty {
                        LabeledContent("Current username", value: username)
                    }
                }
                Section("Personalize PausePath") {
                    NavigationLink("Update Walking Preferences") { PlannerView(preferences: $preferences, health: health) }
                    NavigationLink("Update Goals") { GoalPreferencesEditor(preferences: $preferences) }
                }
                Section("Account and privacy") {
                    NavigationLink("Account settings") { AccountView() }
                    Text("Your username is shown to members of communities you join. You can use a nickname instead of your real name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Profile")
        }
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
        }.navigationTitle("Update Goals")
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
            }.navigationTitle("My progress")
        }
    }
}
