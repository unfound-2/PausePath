import SwiftUI
import MapKit

struct LiveRouteControls: View {
    let preferences: RoutePreferences
    @State private var builder = WalkingRouteBuilder()
    @State private var locator = WalkingNavigator()
    @State private var query = ""
    @State private var waitingForOrigin = false
    @State private var selected: GeneratedWalk?
    var body: some View {
        Section("Create your walking route") {
            Text("Choose a start. PausePath will create out-and-back walks near your desired distance, with directions for both legs.")
            TextField("Starting address or landmark", text: $query).submitLabel(.search)
                .onSubmit { waitingForOrigin = false; builder.searchOrigin(query) }
                .onChange(of: query) { builder.invalidate(); builder.origin = nil; builder.originName = "Find the new starting point" }
            HStack {
                Button("Find start") { waitingForOrigin = false; builder.searchOrigin(query) }.disabled(query.isEmpty || builder.isLoading)
                Spacer()
                Button("Use my location") { waitingForOrigin = true; locator.locate() }.disabled(builder.isLoading)
            }.buttonStyle(.bordered)
            Text(builder.originName).font(.headline)
            if waitingForOrigin { Text(locator.status).font(.caption) }
            if let origin = builder.origin {
                Map(initialPosition: .region(MKCoordinateRegion(center: origin.mapCoordinate, latitudinalMeters: 600, longitudinalMeters: 600))) {
                    Marker("Start", coordinate: origin.mapCoordinate)
                }.frame(height: 160).id(origin)
            }
            Button {
                builder.generate(preferences: preferences)
            } label: {
                HStack { if builder.isLoading { ProgressView() }; Text(builder.isLoading ? "Creating routes…" : "Create walking routes") }
            }.disabled(builder.origin == nil || builder.isLoading)
            if builder.isLoading { Button("Cancel route search") { builder.cancel(); builder.status = "Route search cancelled." } }
            Text(builder.status).font(.caption).foregroundStyle(.secondary)
            ForEach(builder.candidates) { walk in
                Button { selected = walk } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(walk.name).font(.headline)
                        Text("\(walk.distance / 1000, specifier: "%.1f") km • about \(Int(walk.duration / 60)) min • out and back").font(.subheadline)
                        Text("Review route and start navigation").font(.caption)
                    }
                }
            }
            Text("Distance-based routes: slope, seating gaps and facility availability cannot yet be verified. You’ll review these limits before starting.").font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: locator.location?.timestamp) {
            guard waitingForOrigin, let location = locator.location, locator.freshLocation() else { return }
            waitingForOrigin = false
            builder.setOrigin(Coordinate(location.coordinate.latitude, location.coordinate.longitude), name: "Your current location")
        }
        .onChange(of: preferences) { builder.invalidate(); builder.status = "Preferences changed. Create new routes to use them." }
        .onDisappear { builder.cancel() }
        .fullScreenCover(item: $selected) { walk in WalkingNavigationView(walk: walk) }
    }
}

struct WalkingNavigationView: View {
    let walk: GeneratedWalk
    @State private var navigator = WalkingNavigator()
    @State private var weatherGuidance = WeatherGuidanceStore()
    @State private var camera: MapCameraPosition = .automatic
    @State private var acknowledged = false
    @State private var takingBreak = false
    @State private var suggestedStops: [SharedPOI] = []
    @State private var showEndConfirmation = false
    @State private var showReturnConfirmation = false
    @AppStorage("pausepath.weather.openMeteo.guidance.enabled") private var weatherGuidanceEnabled = false
    @AppStorage("pausepath.weather.openMeteo.walkUpdates.enabled") private var weatherWalkUpdatesEnabled = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private var plan: GeneratedWalk { navigator.plan ?? walk }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Map(position: $camera) {
                        UserAnnotation()
                        ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                            MapPolyline(leg.polyline).stroke(index == navigator.progress.legIndex ? .teal : .blue.opacity(0.5), lineWidth: index == navigator.progress.legIndex ? 7 : 4)
                        }
                        ForEach(suggestedStops.filter { !$0.unavailable && $0.location.coordinates.count == 2 }) { poi in
                            Marker(poi.name ?? "Break stop", systemImage: FacilityKind.fromAPI(poi.category)?.symbol ?? "mappin", coordinate: poi.coordinate).tint(.orange)
                        }
                        Marker("Start", coordinate: walk.start.mapCoordinate)
                        if let turn = walk.paths.first?.last { Marker(walk.legs.count > 1 ? "Turnaround" : "Destination", systemImage: "flag.fill", coordinate: turn.mapCoordinate) }
                    }.mapControls { MapCompass(); MapScaleView() }.frame(height: 300)
                    HStack {
                        Button("Follow me", systemImage: "location.fill") { camera = .userLocation(followsHeading: true, fallback: .automatic) }
                        Spacer()
                        Button("Whole route", systemImage: "map") { camera = .automatic }
                    }
                    if navigator.state == .ready {
                        Text("\(plan.distance / 1000, specifier: "%.1f") km • about \(Int(plan.duration / 60)) min").font(.title2.bold())
                        Text(plan.requirements).font(.subheadline)
                        Text("This route follows Apple walking directions. Terrain, distance between seats, and facility opening hours are unverified; it is not a confirmed match for those requirements.").font(.callout)
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
                        Text("Navigation works while PausePath is open. It pauses when the app goes into the background. Your screen stays on during guidance.").font(.caption).foregroundStyle(.secondary)
                        Button("Start navigation", systemImage: "figure.walk") {
                            navigator.start(); camera = .userLocation(followsHeading: true, fallback: .automatic)
                        }.buttonStyle(.borderedProminent).disabled(!acknowledged)
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
                    RouteBreaksView(walk: plan, currentLocation: navigator.freshLocation() ? navigator.location?.coordinate : nil,
                        onDetour: { takingBreak = true; navigator.pause() }, onReturn: { takingBreak = false },
                        onStopsChanged: { suggestedStops = $0 })
                        .id(plan.id)
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
            }.navigationTitle("Your walking route").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button(navigator.state == .ready || navigator.state == .arrived ? "Close" : "End walk") {
                    if navigator.state == .ready || navigator.state == .arrived { navigator.stop(); dismiss() }
                    else { showEndConfirmation = true }
                } }
                .confirmationDialog("End this walk?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
                    Button("End navigation", role: .destructive) { navigator.stop(); dismiss() }
                }
                .confirmationDialog("Replace the remaining walk with directions back to your original start? Distance will change; rest stops and terrain remain unverified.", isPresented: $showReturnConfirmation, titleVisibility: .visible) {
                    Button("Return to start") { navigator.returnToStart() }
                }
        }
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
        .onDisappear { if !takingBreak { navigator.stop() } }
        .onChange(of: scenePhase) { if scenePhase == .background { navigator.pause() } }
        .onChange(of: navigator.plan?.id) { camera = .automatic; suggestedStops = [] }
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
            Text("\(navigator.remainingMeters / 1000, specifier: "%.2f") km remaining • about \(Int(navigator.remainingMeters / max(0.3, plan.preferences.speedMetersPerSecond) / 60)) min").font(.subheadline)
            Text("Leg \(min(navigator.progress.legIndex + 1, plan.legs.count)) of \(plan.legs.count) • time excludes breaks").font(.caption)
            if navigator.state != .arrived {
                HStack {
                    Button(navigator.state == .paused ? "Resume" : "Pause") { if navigator.state == .paused { navigator.start() } else { navigator.pause() } }
                        .buttonStyle(.borderedProminent)
                    Button("Return to start") { showReturnConfirmation = true }.disabled(navigator.isRecalculating || navigator.state != .walking)
                }
                if navigator.progress.offRoute {
                    Button("Recalculate remaining walk") { navigator.recalculate(returnToStart: false) }.disabled(navigator.isRecalculating || navigator.state != .walking)
                    Text("Recalculation changes distance. Terrain and rest-stop requirements remain unverified.").font(.caption)
                }
                if navigator.isRecalculating { ProgressView("Finding a new walking path…") }
            }
        }
    }
}
