import SwiftUI
import MapKit

struct WalkingNavigationView: View {
    let walk: GeneratedWalk
    @State private var navigator = WalkingNavigator()
    @State private var weatherGuidance = WeatherGuidanceStore()
    @State private var camera: MapCameraPosition = .automatic
    @State private var acknowledged = false
    @State private var savedRoute = false
    @State private var saveMessage = ""
    @State private var showWeather = false
    @State private var showWalkSettings = false
    @State private var recordingOwner = PausePathAccount.shared.userID
    @State private var takingBreak = false
    @State private var suggestedStops: [SharedPOI] = []
    @State private var showEndConfirmation = false
    @State private var showReturnConfirmation = false
    @State private var walkCompletionMessage = ""
    @State private var walkRecorded = false
    @State private var checkInWalk: TrackedWalk?
    @State private var checkInFeeling: Manageability?
    @State private var checkInFacilities: Bool?
    @State private var checkInNote = ""
    @AppStorage("pausepath.walk.background") private var backgroundWalks = true
    @AppStorage("pausepath.walk.liveActivity") private var liveActivities = true
    @State private var milestoneMessage: String?
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.walkFeedback") private var feedbackData = Data()
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
                        routeReadyControls
                    } else {
                        navigationStatus
                    }
                    HStack(spacing: 12) {
                        Button("Weather", systemImage: "cloud.sun") { showWeather = true }
                        Spacer()
                        Button("Walk settings", systemImage: "slider.horizontal.3") { showWalkSettings = true }
                    }.font(.subheadline).frame(minHeight: 44)
                    if navigator.state != .ready { NextPauseCard(navigator: navigator) }
                    DisclosureGroup("More stops") {
                    RouteBreaksView(walk: plan, currentLocation: navigator.freshLocation() ? navigator.location?.coordinate : nil,
                        onDetour: { takingBreak = true; navigator.pause() }, onReturn: { takingBreak = false },
                        onStopsChanged: { suggestedStops = $0 })
                        .id(plan.id)
                    }
                    if let milestoneMessage {
                        Label(milestoneMessage, systemImage: "trophy.fill").font(.headline)
                            .padding().frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(PausePathPalette.ink)
                            .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 18))
                    }
                    if !navigator.freshLocation() && navigator.state != .ready {
                        Text(navigator.status).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("All directions") {
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
        .navigationTitle(navigator.state == .ready ? "Route preview" : "Your walk").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(navigator.state == .ready || navigator.state == .arrived ? "Close" : "End walk") {
                    if navigator.state == .ready || navigator.state == .arrived { navigator.stop(); dismiss() }
                    else { showEndConfirmation = true }
                } }
                .confirmationDialog("End this walk?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
                    Button("End walk", role: .destructive) { finishWalk(completed: false) }
                }
                .confirmationDialog("Return to your starting point? This replaces the remaining route.", isPresented: $showReturnConfirmation, titleVisibility: .visible) {
                    Button("Return to start") { navigator.returnToStart() }
                }
        }
        .interactiveDismissDisabled(navigator.state != .ready)
        .sheet(isPresented: $showWeather) { weatherSheet }
        .sheet(isPresented: $showWalkSettings) { walkSettingsSheet }
        .onAppear { if navigator.plan == nil { navigator.prepare(walk) } }
        .task(id: "\(plan.id)-\(weatherGuidanceEnabled)-\(showWeather)") {
            guard weatherGuidanceEnabled, showWeather else { return }
            await weatherGuidance.load(for: plan)
        }
        .task(id: showWeather && weatherGuidanceEnabled && weatherWalkUpdatesEnabled && navigator.state == .walking && scenePhase == .active) {
            guard showWeather, weatherGuidanceEnabled, weatherWalkUpdatesEnabled, navigator.state == .walking, scenePhase == .active else { return }
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
        .sheet(item: $checkInWalk) { recorded in
            NavigationStack {
                Form {
                    if !walkCompletionMessage.isEmpty {
                        Section("Walk complete") { Text(walkCompletionMessage) }
                    }
                    Section("How did this walk feel?") {
                        ForEach(Manageability.allCases, id: \.self) { feeling in
                            Button { checkInFeeling = feeling } label: {
                                HStack { Text(feeling.rawValue); Spacer(); if checkInFeeling == feeling { Image(systemName: "checkmark") } }
                            }
                        }
                    }
                    Section("Were the planned facilities available?") {
                        HStack {
                            Button("Yes") { checkInFacilities = true }
                            Button("No") { checkInFacilities = false }
                            Button("Not sure") { checkInFacilities = nil }
                        }
                        Text(checkInFacilities.map { $0 ? "Available" : "Unavailable" } ?? "Unknown")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Optional note") { TextField("Anything to remember?", text: $checkInNote, axis: .vertical).lineLimit(2...4) }
                    Section { Text("Your check-in stays on this device. It can help order future routes, but it never changes your walking preferences automatically or judges medical readiness.")
                        .font(.footnote).foregroundStyle(.secondary) }
                }
                .pausePathSurface().navigationTitle("Walk check-in")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Skip") { closeCheckIn() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            if let feeling = checkInFeeling {
                                var feedback = (try? JSONDecoder().decode([WalkFeedback].self, from: feedbackData)) ?? []
                                feedback.insert(WalkFeedback(routeName: recorded.routeName, manageability: feeling,
                                    facilitiesAvailable: checkInFacilities, note: checkInNote, activityID: recorded.id.uuidString), at: 0)
                                feedbackData = (try? JSONEncoder().encode(feedback)) ?? feedbackData
                            }
                            closeCheckIn()
                        }.disabled(checkInFeeling == nil)
                    }
                }
            }
        }
    }
    private func closeCheckIn() { checkInWalk = nil; walkCompletionMessage = ""; navigator.stop(); dismiss() }
    private var routeReadyControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(plan.distance / 1000, specifier: "%.1f") km · \(max(1, Int(plan.duration / 60))) min").font(.title2.bold())
                Spacer()
                Button(savedRoute ? "Saved" : "Save", systemImage: savedRoute ? "heart.fill" : "heart") {
                    if var record = SavedRouteStore.saveWalk(plan) { record.isFavorite = true; SavedRouteStore.update(record); savedRoute = true }
                    else { saveMessage = "Route library full. Remove a saved route in Profile." }
                }.disabled(savedRoute).buttonStyle(.bordered)
            }
            if !saveMessage.isEmpty { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
            Label("Stop access and terrain may be unverified", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
            if plan.restAssessment.status == .exceeds {
                Label("Rest gap exceeds your preference", systemImage: "exclamationmark.circle").font(.subheadline)
            }
            Toggle("I'll check route conditions", isOn: $acknowledged).font(.subheadline).tint(PausePathPalette.teal)
            Button("Start walk", systemImage: "figure.walk") {
                navigator.backgroundEnabled = backgroundWalks; navigator.liveActivityEnabled = liveActivities
                navigator.start(); camera = .userLocation(followsHeading: true, fallback: .automatic)
            }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                .controlSize(.large).disabled(!acknowledged)
            DisclosureGroup("Route details") {
                RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: plan.distance, durationSeconds: plan.duration))
                RestGapStatusCard(assessment: plan.restAssessment, limit: plan.preferences.maximumRestGapMeters)
                Text(plan.requirements).font(.caption).foregroundStyle(.secondary)
            }.font(.subheadline)
        }
    }
    private var weatherSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if weatherGuidanceEnabled {
                        WeatherGuidanceCard(store: weatherGuidance)
                        if let update = weatherGuidance.updateMessage { Text(update).font(.callout) }
                    } else {
                        Button("Check route weather", systemImage: "cloud.sun") { weatherGuidanceEnabled = true }.buttonStyle(.borderedProminent)
                    }
                    Toggle("Refresh during this walk", isOn: $weatherWalkUpdatesEnabled).disabled(!weatherGuidanceEnabled)
                    DisclosureGroup("About weather") {
                        Text("Forecasts use approximate route locations sent to Open-Meteo. Conditions can change. Weather preferences are in Account settings.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }.pausePathSurface().navigationTitle("Weather").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWeather = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private var walkSettingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Spoken directions", isOn: Binding(get: { navigator.voiceEnabled }, set: { navigator.setVoice($0) }))
                    Toggle("Navigate while phone is locked", isOn: $backgroundWalks).disabled(navigator.state != .ready && navigator.state != .paused)
                    Toggle("Lock Screen activity", isOn: $liveActivities).disabled(navigator.state != .ready && navigator.state != .paused)
                    if navigator.state != .ready && navigator.state != .paused { Text("Pause to change Lock Screen settings.").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Text("Start enables location tracking, including while locked if selected. Pause or End stops tracking. Lock Screen activity may show route instructions and the next stop.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = navigator.liveActivityMessage { Section { Text(message).font(.caption) } }
            }.pausePathSurface().navigationTitle("Walk settings").navigationBarTitleDisplayMode(.inline)
                .onChange(of: backgroundWalks) { _, value in navigator.backgroundEnabled = value }
                .onChange(of: liveActivities) { _, value in navigator.liveActivityEnabled = value }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWalkSettings = false } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private var navigationStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let fresh = navigator.freshLocation(at: timeline.date)
                Text(navigator.state == .paused ? "Walk paused" : (!fresh && navigator.state != .arrived ? "Waiting for accurate GPS" : navigator.currentInstruction)).font(.title2.bold())
                if fresh, navigator.state == .walking, !navigator.progress.offRoute, navigator.progress.hasStarted, let step = navigator.stepDetails {
                    Text("In \(Int(step.meters)) m").foregroundStyle(.secondary)
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
            Text("\(navigator.remainingMeters / 1000, specifier: "%.1f") km left · \(max(1, Int(navigator.remainingMeters / max(0.3, plan.preferences.speedMetersPerSecond) / 60))) min")
                .font(.subheadline.weight(.semibold))
            if navigator.remainingRestAssessment.status == .exceeds {
                Label("Next rest gap exceeds your preference", systemImage: "exclamationmark.circle").font(.caption)
            }
            DisclosureGroup("Route details") {
                RestGapStatusCard(assessment: navigator.remainingRestAssessment, limit: plan.preferences.maximumRestGapMeters)
            }.font(.subheadline)
            if navigator.state != .arrived {
                HStack {
                    Button(navigator.state == .paused ? "Resume" : "Pause") { if navigator.state == .paused { navigator.start() } else { navigator.pause() } }
                        .buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                    Button("Return to start") { showReturnConfirmation = true }.disabled(navigator.isRecalculating || navigator.state != .walking)
                }
                if navigator.progress.offRoute {
                    Button("Recalculate remaining walk") { navigator.recalculate(returnToStart: false) }.disabled(navigator.isRecalculating || navigator.state != .walking)
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
            steps: navigator.recordedSteps, startedAt: navigator.journeyStartedAt, journeySegments: navigator.journeySegments, activityKind: "Walking", ownerID: recordingOwner)
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
        if completed {
            let distanceText = distance >= 1_000
                ? String(format: "%.2f km", distance / 1_000)
                : String(format: "%.0f m", distance)
            walkCompletionMessage = "\(distanceText) recorded in \(elapsedText(activity.activeSeconds)) active time. Saved in My Path."
        } else {
            navigator.stop()
        }
        checkInWalk = activity
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
