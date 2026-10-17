import SwiftUI
import MapKit
import AuthenticationServices

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var preferences = RoutePreferences()
    @AppStorage("pausepath.preferences") private var preferencesData = Data()
    let health: HealthActivityStore
    var body: some View {
        TabView {
            DiscoverView(preferences: preferences).tabItem { Label("Explore", systemImage: "map.fill") }
            PlannerView(preferences: $preferences, health: health).tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }
            ReviewView(preferences: $preferences, health: health).tabItem { Label("My progress", systemImage: "chart.bar.fill") }
            AccountView().tabItem { Label("Account", systemImage: "person.crop.circle") }
        }.tint(Color(red: 0.12, green: 0.40, blue: 0.32))
        .onAppear {
            if var saved = try? JSONDecoder().decode(RoutePreferences.self, from: preferencesData) {
                saved.departure = Date()
                preferences = saved
            }
        }
        .task { await PausePathAccount.shared.checkAppleCredential() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { Task { await PausePathAccount.shared.checkAppleCredential() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: ASAuthorizationAppleIDProvider.credentialRevokedNotification)) { _ in
            Task { await PausePathAccount.shared.checkAppleCredential() }
        }
        .onChange(of: preferences) { preferencesData = (try? JSONEncoder().encode(preferences)) ?? Data() }
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
    @AppStorage("pausepath.feedback") private var feedbackData = Data()
    @AppStorage("pausepath.weeklyGoalKM") private var weeklyGoal = 5.0
    @State private var manageability: Manageability = .aboutRight
    @State private var facilitiesAvailable = true
    @State private var note = ""
    @State private var routeName = ""
    @State private var activityID = ""
    @State private var message = ""
    private var feedback: [WalkFeedback] { (try? JSONDecoder().decode([WalkFeedback].self, from: feedbackData)) ?? [] }
    private var weeklyDistance: Double {
        let interval = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        return health.activities.filter { interval.contains($0.date) }.reduce(0) { $0 + $1.meters } / 1000
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
                Section("This week") {
                    Stepper("Distance goal: \(weeklyGoal, specifier: "%.1f") km", value: $weeklyGoal, in: 0.5...100, step: 0.5)
                    ProgressView(value: min(weeklyDistance, weeklyGoal), total: weeklyGoal)
                    Text("\(weeklyDistance, specifier: "%.1f") / \(weeklyGoal, specifier: "%.1f") km from available Health walks")
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
                Section("Reflect on a walk") {
                    TextField("Route or walk name", text: $routeName)
                    Picker("Activity (optional)", selection: $activityID) {
                        Text("No linked activity").tag("")
                        ForEach(health.activities) { Text($0.date.formatted(date: .abbreviated, time: .shortened)).tag($0.id) }
                    }
                    Picker("How did it feel?", selection: $manageability) { ForEach(Manageability.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Toggle("The facilities I needed were available", isOn: $facilitiesAvailable)
                    TextField("Notes about stops or the walk", text: $note, axis: .vertical)
                    Button("Save feedback on this device") {
                        let entry = WalkFeedback(routeName: routeName.trimmingCharacters(in: .whitespacesAndNewlines), manageability: manageability, facilitiesAvailable: facilitiesAvailable, note: note, activityID: activityID.isEmpty ? nil : activityID)
                        feedbackData = (try? JSONEncoder().encode([entry] + feedback)) ?? feedbackData
                        note = ""; routeName = ""; message = "Feedback saved. Preferences stay unchanged until you choose an adjustment."
                    }.disabled(routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let latest = feedback.first {
                    Section("Your next walk, your choice") {
                        Text("Last reflection: \(latest.manageability.rawValue.lowercased()). \(latest.facilitiesAvailable ? "Facilities were available." : "Some facilities were unavailable.")")
                        if let activity = health.activities.first(where: { $0.id == latest.activityID }) {
                            Text("Linked walk: \(activity.meters / 1000, specifier: "%.1f") km in \(Int(activity.seconds / 60)) min. Use this context alongside your own feedback.").font(.caption)
                        }
                        ForEach(RouteAdjustment.allCases, id: \.self) { adjustment in
                            Button(adjustment.rawValue) { adjustment.apply(to: &preferences); message = "Applied: \(adjustment.rawValue). Review your preferences in Plan." }
                        }
                        Text("These are optional preference changes, not medical recommendations. Heart rate never determines route adjustments.").font(.caption)
                    }
                }
                if !message.isEmpty { Text(message).font(.callout).accessibilityIdentifier("feedbackStatus") }
                Section("Saved reflections") {
                    ForEach(feedback) { entry in
                        VStack(alignment: .leading) {
                            Text(entry.routeName).font(.headline)
                            Text("\(entry.manageability.rawValue) • \(entry.date.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                            if !entry.note.isEmpty { Text(entry.note) }
                        }
                    }
                    if !feedback.isEmpty { Button("Delete saved feedback", role: .destructive) { feedbackData = Data(); message = "Saved feedback deleted." } }
                }
            }.navigationTitle("My progress")
        }
    }
}
