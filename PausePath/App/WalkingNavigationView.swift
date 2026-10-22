import SwiftUI
import MapKit

struct WalkingNavigationView: View {
    let walk: GeneratedWalk
    @State private var navigator = WalkingNavigator()
    @State private var weatherGuidance = WeatherGuidanceStore()
    @State private var camera: MapCameraPosition = .automatic
    @State private var acknowledged = false
    @State private var activityKind = "Walking"
    @State private var recordingOwner = PausePathAccount.shared.userID
    @State private var takingBreak = false
    @State private var suggestedStops: [SharedPOI] = []
    @State private var showEndConfirmation = false
    @State private var showReturnConfirmation = false
    @State private var walkRecorded = false
    @AppStorage("pausepath.walk.background") private var backgroundWalks = true
    @AppStorage("pausepath.walk.liveActivity") private var liveActivities = true
    @State private var milestoneMessage: String?
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.weather.openMeteo.guidance.enabled") private var weatherGuidanceEnabled = true
    @AppStorage("pausepath.weather.openMeteo.walkUpdates.enabled") private var weatherWalkUpdatesEnabled = true
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var plan: GeneratedWalk { navigator.plan ?? walk }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Map(position: $camera) {
                        if let coordinate = navigator.displayCoordinate {
                            Annotation("Your location", coordinate: coordinate.mapCoordinate) {
                                Image(systemName: "location.north.fill")
                                    .font(.title3.weight(.bold)).foregroundStyle(.white)
                                    .frame(width: 40, height: 40).background(Color.blue, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 3)
                                    .accessibilityLabel("Your current location")
                            }.annotationTitles(.hidden)
                        }
                        ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                            MapPolyline(leg.polyline).stroke(index == navigator.progress.legIndex ? PausePathPalette.teal : .blue.opacity(0.5), lineWidth: index == navigator.progress.legIndex ? 7 : 4)
                        }
                        let endsNearStart = plan.paths.last?.last.map { WalkingGeometry.distance(plan.start, $0) <= 40 } ?? false
                        if endsNearStart, let turnaround = plan.paths.first?.last {
                            Marker("Turnaround", systemImage: "arrow.uturn.down", coordinate: turnaround.mapCoordinate).tint(.orange)
                        } else {
                            ForEach(Array(plan.legs.dropLast().enumerated()), id: \.offset) { index, leg in
                                if let coordinate = leg.polyline.walkingCoordinates.last?.mapCoordinate {
                                    Marker("Stop \(index + 1)", systemImage: "mappin.and.ellipse", coordinate: coordinate).tint(.orange)
                                }
                            }
                        }
                        ForEach(suggestedStops.filter { !$0.unavailable && $0.location.coordinates.count == 2 }) { poi in
                            Marker(poi.name ?? "Break stop", systemImage: FacilityKind.fromAPI(poi.category)?.symbol ?? "mappin", coordinate: poi.coordinate).tint(.orange)
                        }
                        Marker("Start", coordinate: plan.start.mapCoordinate)
                        if let end = plan.paths.last?.last {
                            Marker(endsNearStart ? "Finish" : "Destination", systemImage: "flag.fill", coordinate: end.mapCoordinate)
                        }
                    }.mapControls { MapCompass(); MapScaleView() }.frame(height: 300)
                    HStack {
                        Button("Recenter", systemImage: "location.fill") {
                            if let coordinate = navigator.displayCoordinate { camera = .region(MKCoordinateRegion(center: coordinate.mapCoordinate, latitudinalMeters: 500, longitudinalMeters: 500)) }
                            else { camera = .automatic }
                        }
                        Spacer()
                        Button("Whole route", systemImage: "map") { camera = .automatic }
                    }
                    if navigator.state == .ready {
                        Picker("Activity", selection: $activityKind) {
                            ForEach(["Walking", "Running", "Hiking"], id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.segmented)
                        Text("Directions and time estimates use walking pace. Your recorded time reflects your actual activity.").font(.caption).foregroundStyle(.secondary)

                        Text("\(plan.distance / 1000, specifier: "%.1f") km • about \(Int(plan.duration / 60)) min").font(.title2.bold())
                        RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: plan.distance, durationSeconds: plan.duration))
                        Text(plan.requirements).font(.subheadline)
                        RestGapStatusCard(assessment: plan.restAssessment, limit: plan.preferences.maximumRestGapMeters)
                        Text("This route follows Apple walking directions. Rest gaps use the mapped stops shown above. Terrain and unverified facility details remain unknown; real-world conditions can change.").font(.callout)
                        if weatherGuidanceEnabled {
                            WeatherGuidanceCard(store: weatherGuidance)
                        } else {
                            Button("Check weather for this route", systemImage: "cloud.sun.fill") {
                                weatherGuidanceEnabled = true
                            }.buttonStyle(.bordered)
                            Text("Checking sends up to three approximate route locations to Open-Meteo. Forecasts are cached in memory for 15 minutes. Open-Meteo may retain request logs for up to 90 days.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Show weather updates during this walk", isOn: $weatherWalkUpdatesEnabled)
                            .disabled(!weatherGuidanceEnabled)
                        Text("Updates appear in PausePath while navigation is active and the app is open.")
                            .font(.caption).foregroundStyle(.secondary)
                        Toggle("Use this route with those details unverified", isOn: $acknowledged)
                        Toggle("Keep navigating with the phone locked", isOn: $backgroundWalks)
                        Toggle("Show a Live Activity on the Lock Screen", isOn: $liveActivities)
                        Text("Starting a walk allows location updates while locked when enabled. Pause or End stops tracking. The Live Activity can show route instructions and the next stop on your Lock Screen; you can turn it off here.").font(.caption).foregroundStyle(.secondary)
                        Button("Start navigation", systemImage: "figure.walk") {
                            navigator.backgroundEnabled = backgroundWalks; navigator.liveActivityEnabled = liveActivities
                            navigator.start(); camera = .userLocation(followsHeading: true, fallback: .automatic)
                        }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink).disabled(!acknowledged)
                    } else {
                        navigationStatus
                        if weatherGuidanceEnabled {
                            WeatherGuidanceCard(store: weatherGuidance)
                            if let update = weatherGuidance.updateMessage {
                                Label(update, systemImage: "cloud.sun.fill")
                                    .font(.callout)
                                    .padding()
                                    .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                    NextPauseCard(navigator: navigator)
                    if let message = navigator.liveActivityMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    RouteBreaksView(walk: plan, currentLocation: navigator.freshLocation() ? navigator.location?.coordinate : nil,
                        onDetour: { takingBreak = true; navigator.pause() }, onReturn: { takingBreak = false },
                        onStopsChanged: { suggestedStops = $0 })
                        .id(plan.id)
                    if let milestoneMessage {
                        Label(milestoneMessage, systemImage: "trophy.fill").font(.headline)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(PausePathPalette.ink)
                            .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 18))
                    }
                    Text(navigator.status).font(.callout).foregroundStyle(.secondary)
                    Toggle("Spoken directions", isOn: Binding(get: { navigator.voiceEnabled }, set: { navigator.setVoice($0) }))
                    DisclosureGroup("All walking directions") {
                        ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                            Text("Leg \(index + 1)").font(.headline)
                            ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
                                if !step.instructions.isEmpty {
                                    VStack(alignment: .leading) {
                                        Text(step.instructions)
                                        Text("\(Int(step.distance)) m").font(.caption).foregroundStyle(.secondary)
                                        if let notice = step.notice { Text(notice).font(.caption) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }.padding()
            }.pausePathSurface()
        .navigationTitle("Your walking route").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(navigator.state == .ready || navigator.state == .arrived ? "Close" : "End walk") {
                    if navigator.state == .ready || navigator.state == .arrived { navigator.stop(); dismiss() }
                    else { showEndConfirmation = true }
                } }
                .confirmationDialog("End this walk?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
                    Button("End walk", role: .destructive) { finishWalk(completed: false) }
                }
                .confirmationDialog("Replace the remaining walk with directions back to your original start? Distance will change; rest stops and terrain remain unverified.", isPresented: $showReturnConfirmation, titleVisibility: .visible) {
                    Button("Return to start") { navigator.returnToStart() }
                }
        }
        .interactiveDismissDisabled(navigator.state != .ready)
        .onAppear { if navigator.plan == nil { navigator.prepare(walk) } }
        .task(id: "\(plan.id)-\(weatherGuidanceEnabled)") {
            guard weatherGuidanceEnabled else { weatherGuidance.clear(); return }
            await weatherGuidance.load(for: plan)
        }
        .task(id: weatherGuidanceEnabled && weatherWalkUpdatesEnabled && navigator.state == .walking && scenePhase == .active) {
            guard weatherGuidanceEnabled, weatherWalkUpdatesEnabled, navigator.state == .walking, scenePhase == .active else { return }
            if let coordinate = navigator.location?.coordinate {
                await weatherGuidance.checkForMeaningfulChange(at: coordinate)
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15 * 60)) } catch { return }
                guard !Task.isCancelled, navigator.state == .walking, scenePhase == .active,
                      let coordinate = navigator.location?.coordinate else { continue }
                await weatherGuidance.checkForMeaningfulChange(at: coordinate)
            }
        }
        .onDisappear { if !takingBreak && scenePhase == .active { navigator.stop() } }
        .onChange(of: navigator.plan?.id) { camera = .automatic; suggestedStops = [] }
        .onChange(of: navigator.state) { _, state in
            if state == .arrived { finishWalk(completed: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, !navigator.backgroundEnabled, navigator.state == .walking || navigator.state == .locating {
                navigator.pause()
            }
        }
    }
    private var navigationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let fresh = navigator.freshLocation(at: timeline.date)
                Text(navigator.state == .paused ? "Walk paused" : (!fresh && navigator.state != .arrived ? "Waiting for accurate GPS" : navigator.currentInstruction)).font(.title2.bold())
                if fresh, navigator.state == .walking, !navigator.progress.offRoute, navigator.progress.hasStarted, let step = navigator.stepDetails {
                    Text("Follow this step for about \(Int(step.meters)) m")
                }
            }
            ProgressView(value: min(navigator.progress.completedMeters, navigator.progress.totalMeters), total: max(1, navigator.progress.totalMeters))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                HStack {
                    Label("Walk time", systemImage: "timer")
                    Spacer()
                    Text(elapsedText(navigator.elapsedActiveSeconds)).monospacedDigit().fontWeight(.semibold)
                }.font(.subheadline)
            }
            Text("\(navigator.progress.completedMeters / 1000, specifier: "%.2f") km completed • \(navigator.remainingMeters / 1000, specifier: "%.2f") km remaining • about \(Int(navigator.remainingMeters / max(0.3, plan.preferences.speedMetersPerSecond) / 60)) min")
                .font(.subheadline)
            Text("Leg \(min(navigator.progress.legIndex + 1, plan.legs.count)) of \(plan.legs.count) • time excludes breaks").font(.caption)
            Text("Remaining walk").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            RestGapStatusCard(assessment: navigator.remainingRestAssessment, limit: plan.preferences.maximumRestGapMeters)
            if navigator.state != .arrived {
                HStack {
                    Button(navigator.state == .paused ? "Resume" : "Pause") { if navigator.state == .paused { navigator.start() } else { navigator.pause() } }
                        .buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                    Button("Return to start") { showReturnConfirmation = true }.disabled(navigator.isRecalculating || navigator.state != .walking)
                }
                if navigator.progress.offRoute {
                    Button("Recalculate remaining walk") { navigator.recalculate(returnToStart: false) }.disabled(navigator.isRecalculating || navigator.state != .walking)
                    Text("Recalculation changes distance. Review the updated rest gap below.").font(.caption)
                }
                if navigator.isRecalculating { ProgressView("Finding a new walking path…") }
            }
        }
    }

    private func finishWalk(completed: Bool) {
        guard !walkRecorded else { return }
        walkRecorded = true
        var tracked = (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? []
        let distance = navigator.recordedDistanceMeters
        let activity = TrackedWalk(routeName: plan.name, distanceMeters: distance,
            activeSeconds: navigator.elapsedActiveSeconds, completed: completed, routeIdentity: plan.routeIdentity,
            steps: navigator.recordedSteps, startedAt: navigator.journeyStartedAt, journeySegments: navigator.journeySegments, activityKind: activityKind, ownerID: recordingOwner)
        let previousBest = PathMilestones(walks: tracked).longest
        tracked.insert(activity, at: 0)
        let defaults = UserDefaults.standard
        var earned = defaults.data(forKey: "pausepath.earnedBadges.v1")
            .flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
        let newBadges = PathMilestones(walks: tracked).badges.filter { $0.earned && earned[$0.id] == nil }
        for badge in newBadges { earned[badge.id] = Date() }
        if let data = try? JSONEncoder().encode(earned) { defaults.set(data, forKey: "pausepath.earnedBadges.v1") }
        if completed, previousBest > 0, distance > previousBest {
            milestoneMessage = "A new distance PR! " + String(format: "%.2f km", distance / 1000) + ". See your milestones in My Path."
        } else if completed, let badge = newBadges.first {
            milestoneMessage = "Badge earned: " + badge.name + ". Find your collection in Profile."
        }
        trackedWalkData = (try? JSONEncoder().encode(tracked)) ?? trackedWalkData
        NotificationCenter.default.post(name: .pausePathWalkRecorded, object: activity)
        Task {
            do { try await PausePathAPI.syncChallengeProgress(walks: tracked) }
            catch {
                #if DEBUG
                print("PausePath community progress sync failed: \(error.localizedDescription)")
                #endif
            }
        }
        Task { await DailyRecapNotifications.schedule() }
        if !completed { navigator.stop(); dismiss() }
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
