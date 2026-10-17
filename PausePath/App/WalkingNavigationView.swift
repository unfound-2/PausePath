import SwiftUI
import MapKit

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
    @State private var showReflection = false
    @State private var reflectionPrompted = false
    @State private var reflectionCompleted = false
    @State private var reflectionDistanceMeters = 0.0
    @State private var reflectionActiveSeconds = 0.0
    @State private var walkRecorded = false
    @AppStorage("pausepath.trackedWalks") private var trackedWalkData = Data()
    @AppStorage("pausepath.walkReflections") private var reflectionData = Data()
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
                            MapPolyline(leg.polyline).stroke(index == navigator.progress.legIndex ? .teal : .blue.opacity(0.5), lineWidth: index == navigator.progress.legIndex ? 7 : 4)
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
                        Text("\(plan.distance / 1000, specifier: "%.1f") km • about \(Int(plan.duration / 60)) min").font(.title2.bold())
                        RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: plan.distance, durationSeconds: plan.duration))
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
                        Text("Location updates run only while a walk is active and PausePath is open. Tracking pauses when you pause the walk or leave the app, and ends when you finish.").font(.caption).foregroundStyle(.secondary)
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
                    Button("End walk and reflect", role: .destructive) { presentReflection(completed: false) }
                }
                .confirmationDialog("Replace the remaining walk with directions back to your original start? Distance will change; rest stops and terrain remain unverified.", isPresented: $showReturnConfirmation, titleVisibility: .visible) {
                    Button("Return to start") { navigator.returnToStart() }
                }
                .sheet(isPresented: $showReflection) {
                    WalkReflectionSheet(routeName: plan.name, distanceMeters: reflectionDistanceMeters,
                        activeSeconds: reflectionActiveSeconds, completed: reflectionCompleted,
                        onSave: saveReflection, onSkip: leaveAfterReflection)
                        .interactiveDismissDisabled(true)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        }
        .interactiveDismissDisabled(navigator.state != .ready || showReflection)
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
        .onChange(of: navigator.plan?.id) { camera = .automatic; suggestedStops = [] }
        .onChange(of: navigator.state) { _, state in
            if state == .arrived { presentReflection(completed: true) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, navigator.state == .walking || navigator.state == .locating {
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

    private func presentReflection(completed: Bool) {
        guard !reflectionPrompted else { return }
        reflectionPrompted = true
        reflectionCompleted = completed
        reflectionDistanceMeters = completed ? plan.distance : navigator.progress.completedMeters
        reflectionActiveSeconds = navigator.elapsedActiveSeconds
        guard !walkRecorded else { showReflection = true; return }
        walkRecorded = true
        var tracked = (try? JSONDecoder().decode([TrackedWalk].self, from: trackedWalkData)) ?? []
        let activity = TrackedWalk(routeName: plan.name, distanceMeters: reflectionDistanceMeters,
            activeSeconds: reflectionActiveSeconds, completed: completed, routeIdentity: plan.routeIdentity)
        tracked.insert(activity, at: 0)
        trackedWalkData = (try? JSONEncoder().encode(Array(tracked.prefix(500)))) ?? trackedWalkData
        NotificationCenter.default.post(name: .pausePathWalkRecorded, object: activity)
        Task {
            do { try await PausePathAPI.syncChallengeProgress(walks: tracked) }
            catch {
                #if DEBUG
                print("PausePath community progress sync failed: \(error.localizedDescription)")
                #endif
            }
        }
        if !completed { navigator.pause() }
        showReflection = true
    }

    private func saveReflection(feeling: Manageability, note: String) {
        var reflections = (try? JSONDecoder().decode([WalkReflection].self, from: reflectionData)) ?? []
        let reflection = WalkReflection(routeName: plan.name, feeling: feeling,
            distanceMeters: reflectionDistanceMeters, activeSeconds: reflectionActiveSeconds,
            completed: reflectionCompleted, note: note.isEmpty ? nil : note)
        reflections.insert(reflection, at: 0)
        reflectionData = (try? JSONEncoder().encode(Array(reflections.prefix(200)))) ?? reflectionData
        NotificationCenter.default.post(name: .pausePathWalkReflectionSaved, object: reflection)
        Task { await DailyRecapNotifications.schedule(for: reflection) }
        leaveAfterReflection()
    }

    private func leaveAfterReflection() {
        showReflection = false
        navigator.stop()
        dismiss()
    }

    private func elapsedText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct WalkReflectionSheet: View {
    let routeName: String
    let distanceMeters: Double
    let activeSeconds: Double
    let completed: Bool
    let onSave: (Manageability, String) -> Void
    let onSkip: () -> Void
    @State private var feeling: Manageability?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(completed ? "You made it to your destination" : "Walk ended")
                        .font(.title2.bold())
                    Text("\(routeName) • \(distanceMeters / 1000, specifier: "%.1f") km • \(elapsedText(activeSeconds)) moving time")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text("How did that walk feel?").font(.headline)
                HStack(spacing: 0) {
                    faceChoice(.comfortable, label: "Good")
                    Spacer(minLength: 8)
                    faceChoice(.aboutRight, label: "Okay")
                    Spacer(minLength: 8)
                    faceChoice(.difficult, label: "Hard")
                }.frame(maxWidth: .infinity)
                TextField("A note for yourself (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3).textFieldStyle(.roundedBorder)
                Button("Save reflection") { if let feeling { onSave(feeling, String(note.prefix(280))) } }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(feeling == nil)
                Button("Skip reflection", action: onSkip)
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity)
                Text("Your reflection stays on this device. It isn’t medical advice and won’t be used to judge your fitness.")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }.padding(22)
                .navigationTitle("Walk reflection")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func faceChoice(_ mood: Manageability, label: String) -> some View {
        Button { feeling = mood } label: {
            VStack(spacing: 6) {
                ReflectionFace(mood: mood, selected: feeling == mood).frame(width: 64, height: 64)
                Text(label).font(.subheadline.weight(.semibold))
            }.padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel("\(label), walk felt \(mood.rawValue.lowercased())")
            .accessibilityAddTraits(feeling == mood ? [.isSelected] : [])
    }

    private func elapsedText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60) : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct ReflectionFace: View {
    let mood: Manageability
    let selected: Bool
    private var color: Color { selected ? .accentColor : .secondary }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let circle = Path(ellipseIn: rect)
            context.fill(circle, with: .color(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)))
            context.stroke(circle, with: .color(color), lineWidth: selected ? 3 : 2)
            for x in [0.36, 0.64] {
                let eye = CGRect(x: size.width * x - 2.2, y: size.height * 0.34, width: 4.4, height: 5.2)
                context.fill(Path(ellipseIn: eye), with: .color(color))
            }
            var mouth = Path()
            switch mood {
            case .comfortable:
                mouth.move(to: CGPoint(x: size.width * 0.27, y: size.height * 0.59))
                mouth.addQuadCurve(to: CGPoint(x: size.width * 0.73, y: size.height * 0.59), control: CGPoint(x: size.width * 0.5, y: size.height * 0.83))
            case .aboutRight:
                mouth.move(to: CGPoint(x: size.width * 0.3, y: size.height * 0.66))
                mouth.addLine(to: CGPoint(x: size.width * 0.7, y: size.height * 0.66))
            case .difficult:
                mouth.move(to: CGPoint(x: size.width * 0.27, y: size.height * 0.72))
                mouth.addQuadCurve(to: CGPoint(x: size.width * 0.73, y: size.height * 0.72), control: CGPoint(x: size.width * 0.5, y: size.height * 0.48))
            }
            context.stroke(mouth, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}
