import SwiftUI
import MapKit

struct WalkingNavigationView: View {
    @AppStorage(DistanceDisplayUnit.storageKey) private var distanceUnitRaw = DistanceDisplayUnit.kilometers.rawValue
    private var distanceUnit: DistanceDisplayUnit { DistanceDisplayUnit(rawValue: distanceUnitRaw) ?? .kilometers }

    let walk: GeneratedWalk
    @State private var navigator = WalkingNavigator()
    @State private var weatherGuidance = WeatherGuidanceStore()
    @State private var camera: MapCameraPosition = .automatic
    @State private var followsUser = true
    @State private var lastCameraCoordinate: Coordinate?
    @State private var lastCameraHeading: Double?
    @State private var showRouteDetails = false
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    private var plan: GeneratedWalk { navigator.plan ?? walk }
    var body: some View {
        NavigationStack {
            Group {
                if navigator.state == .ready { routePreview }
                else { activeNavigation }
            }
                .navigationTitle(navigator.state == .ready ? "Your walking route" : "Your walk")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { if navigator.state == .ready { Button("Close") { navigator.stop(); dismiss() } } }
                .toolbar(navigator.state == .ready ? .visible : .hidden, for: .navigationBar)
                .confirmationDialog("End this walk?", isPresented: $showEndConfirmation, titleVisibility: .visible) {
                    Button("End walk", role: .destructive) { finishWalk(completed: false) }
                }
                .confirmationDialog("Return to your starting point? This replaces the remaining route.", isPresented: $showReturnConfirmation, titleVisibility: .visible) {
                    Button("Return to start") { navigator.returnToStart() }
                }
        }
        .interactiveDismissDisabled(navigator.state != .ready)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if navigator.state == .ready {
                VStack(spacing: 0) {
                    Rectangle().fill(PausePathPalette.teal.opacity(0.16)).frame(height: 1)
                    Button(action: startWalk) {
                        Label("Start navigation", systemImage: "location.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PausePathPalette.ink)
                    .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 18))
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
                .background(PausePathPalette.background)
            }
        }
        .sheet(isPresented: $showWeather) { weatherSheet }
        .sheet(isPresented: $showWalkSettings) { walkSettingsSheet }
        .sheet(isPresented: $showRouteDetails) { activeRouteDetails }
        .onAppear {
            if navigator.plan == nil { navigator.prepare(walk) }
            if navigator.state == .ready { fitPreviewRoute() }
        }
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
        .onChange(of: navigator.plan?.id) {
            if navigator.state == .ready { fitPreviewRoute() } else { updateNavigationCamera() }
            suggestedStops = []
        }
        .onChange(of: navigator.displayCoordinate) { _, _ in updateNavigationCamera() }
        .onChange(of: navigator.headingDegrees) { _, _ in updateNavigationCamera() }
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
                    if let milestoneMessage {
                        Section { Label(milestoneMessage, systemImage: "trophy.fill") }
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
    private var routePreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                routeReadyControls
                routeMap
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                HStack {
                    Button("Recenter", systemImage: "location.fill") {
                        if let coordinate = navigator.displayCoordinate {
                            camera = .region(MKCoordinateRegion(center: coordinate.mapCoordinate,
                                                                 latitudinalMeters: 500, longitudinalMeters: 500))
                        } else { camera = .automatic }
                    }
                    Spacer()
                    Button("Whole route", systemImage: "map") { fitPreviewRoute() }
                }
                previewTimeline
                previewDetails
                HStack(spacing: 10) {
                    Button("Weather", systemImage: "cloud.sun") { showWeather = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    Button("Walk settings", systemImage: "slider.horizontal.3") { showWalkSettings = true }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 8)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                DisclosureGroup("More stops") {
                    RouteBreaksView(walk: plan, currentLocation: navigator.freshLocation() ? navigator.location?.coordinate : nil,
                        onDetour: { takingBreak = true; navigator.pause() }, onReturn: { takingBreak = false },
                        onStopsChanged: { suggestedStops = $0 })
                        .id(plan.id)
                }
                .padding(16)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                DisclosureGroup("All directions") {
                    ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                        Text("Leg \(index + 1)").font(.headline)
                        ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
                            if !step.instructions.isEmpty {
                                VStack(alignment: .leading) {
                                    Text(step.instructions)
                                    Text(distanceUnit.nearby(step.distance)).font(.caption).foregroundStyle(.secondary)
                                    if let notice = step.notice { Text(notice).font(.caption) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }
                        }
                    }
                }
                .padding(16)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
            }
            .padding()
            // The navigation action is pinned above this scroll view. Reserve enough
            // space for the final disclosure row to scroll fully above that action.
            .padding(.bottom, 112)
        }
        .pausePathSurface()
    }
    private func closeCheckIn() { checkInWalk = nil; walkCompletionMessage = ""; navigator.stop(); dismiss() }
    private func startWalk() {
        if navigator.plan == nil { navigator.prepare(walk) }
        navigator.backgroundEnabled = backgroundWalks
        navigator.liveActivityEnabled = liveActivities
        navigator.start()
        followsUser = true
        lastCameraCoordinate = nil
        camera = .userLocation(followsHeading: true, fallback: .automatic)
    }
    private func fitPreviewRoute() {
        let rect = plan.legs.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
        camera = rect.isNull ? .automatic : .rect(rect)
    }
    private func updateNavigationCamera() {
        guard followsUser, navigator.state != .ready, let coordinate = navigator.displayCoordinate else { return }
        let heading = navigator.headingDegrees ?? 0
        if let lastCameraCoordinate, let lastCameraHeading {
            let headingChange = abs(heading - lastCameraHeading).truncatingRemainder(dividingBy: 360)
            if WalkingGeometry.distance(lastCameraCoordinate, coordinate) < 5,
               min(headingChange, 360 - headingChange) < 8 { return }
        }
        lastCameraCoordinate = coordinate
        lastCameraHeading = heading
        let radians = heading * .pi / 180
        let latitudeRadians = coordinate.latitude * .pi / 180
        let forwardMeters = 55.0
        let shiftedLongitude = coordinate.longitude + forwardMeters * sin(radians) / (111_195 * max(0.1, cos(latitudeRadians)))
        let longitude = shiftedLongitude > 180 ? shiftedLongitude - 360 : shiftedLongitude < -180 ? shiftedLongitude + 360 : shiftedLongitude
        let center = CLLocationCoordinate2D(
            latitude: max(-89.9, min(89.9, coordinate.latitude + forwardMeters * cos(radians) / 111_195)),
            longitude: longitude)
        let position = MapCamera(centerCoordinate: center, distance: 420,
                                 heading: heading, pitch: 55)
        withAnimation(.easeOut(duration: 0.55)) { camera = .camera(position) }
    }
    private var routeMap: some View {
        Map(position: $camera) {
            if let coordinate = navigator.displayCoordinate {
                Annotation("Your location", coordinate: coordinate.mapCoordinate) {
                    Image(systemName: "location.north.fill")
                        .font(.headline.weight(.black)).foregroundStyle(PausePathPalette.ink)
                        .frame(width: 42, height: 42)
                        .background(PausePathPalette.lime, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
                        .accessibilityLabel("Your current location")
                }.annotationTitles(.hidden)
            }
            ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                MapPolyline(leg.polyline)
                    .stroke(index == navigator.progress.legIndex ? PausePathPalette.teal : PausePathPalette.teal.opacity(0.65),
                            lineWidth: index == navigator.progress.legIndex ? 8 : 5)
            }
            let endsNearStart = plan.paths.last?.last.map { WalkingGeometry.distance(plan.start, $0) <= 40 } ?? false
            if endsNearStart, let turnaround = plan.paths.first?.last {
                Marker("Turnaround", systemImage: "arrow.uturn.down", coordinate: turnaround.mapCoordinate).tint(PausePathPalette.teal)
            } else {
                ForEach(Array(plan.legs.dropLast().enumerated()), id: \.offset) { index, leg in
                    if let coordinate = leg.polyline.walkingCoordinates.last?.mapCoordinate {
                        let stop = plan.stops.indices.contains(index) ? plan.stops[index] : nil
                        Marker(stop?.item.name ?? "Stop \(index + 1)",
                               systemImage: stop?.kind.symbol ?? "mappin.and.ellipse", coordinate: coordinate)
                            .tint(stop?.kind.mapColor ?? PausePathPalette.teal)
                    }
                }
            }
            ForEach(suggestedStops.filter { !$0.unavailable && $0.location.coordinates.count == 2 }) { poi in
                Marker(poi.name ?? "Break stop", systemImage: FacilityKind.fromAPI(poi.category)?.symbol ?? "mappin",
                       coordinate: poi.coordinate).tint(FacilityKind.fromAPI(poi.category)?.mapColor ?? PausePathPalette.teal)
            }
            Marker("Start", coordinate: plan.start.mapCoordinate)
            if let end = plan.paths.last?.last {
                Marker(endsNearStart ? "Finish" : "Destination", systemImage: "flag.fill", coordinate: end.mapCoordinate)
                    .tint(PausePathPalette.lime)
            }
        }
        .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
    }
    private var activeNavigation: some View {
        ZStack {
            routeMap
                .ignoresSafeArea()
                .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in followsUser = false })
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PAUSEPATH · WALKING")
                            .font(.caption2.weight(.heavy)).tracking(1)
                            .foregroundStyle(PausePathPalette.lime)
                        Text(plan.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Menu {
                        Button("Weather", systemImage: "cloud.sun") { showWeather = true }
                        Button("Walk settings", systemImage: "slider.horizontal.3") { showWalkSettings = true }
                        Button("Return to start", systemImage: "arrow.uturn.backward") { showReturnConfirmation = true }
                            .disabled(navigator.state != .walking || !navigator.freshLocation() || navigator.isRecalculating)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More walk options")
                    Button("End", systemImage: "xmark") { showEndConfirmation = true }
                        .font(.subheadline.weight(.bold))
                        .labelStyle(.titleAndIcon)
                        .frame(minHeight: 44)
                }
                .padding(.horizontal, 17).padding(.vertical, 9)
                .foregroundStyle(.white)
                .background(PausePathPalette.ink.opacity(0.94), in: RoundedRectangle(cornerRadius: 18))
                guidanceBanner
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    mapControl("location.north.fill", label: "Follow me") {
                        followsUser = true; lastCameraCoordinate = nil; updateNavigationCamera()
                    }
                    mapControl("map.fill", label: "Whole route") {
                        followsUser = false; camera = .automatic
                    }
                    Spacer()
                    mapControl(navigator.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                               label: navigator.voiceEnabled ? "Mute directions" : "Speak directions") {
                        navigator.setVoice(!navigator.voiceEnabled)
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView { tripPanel }.frame(maxHeight: 290)
                } else {
                    tripPanel
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(PausePathPalette.background)
    }
    private var guidanceBanner: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: maneuverSymbol)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(PausePathPalette.ink)
                    .frame(width: 54, height: 54)
                    .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 3) {
                    TimelineView(.periodic(from: .now, by: 2)) { timeline in
                        Text(navigator.state == .paused ? "Walk paused" :
                             navigator.isRecalculating ? "Finding a new route…" :
                             !navigator.freshLocation(at: timeline.date) ? "Waiting for GPS" : navigator.currentInstruction)
                            .font(.title3.weight(.bold))
                            .lineLimit(2)
                            .minimumScaleFactor(0.85)
                    }
                    if let step = navigator.stepDetails, navigator.state == .walking, navigator.freshLocation() {
                        Text("In \(distanceUnit.nearby(step.meters))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                }
                Spacer(minLength: 0)
            }
            if navigator.progress.offRoute || navigator.isRecalculating {
                Text(navigator.status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.84))
            }
            if navigator.progress.offRoute, !navigator.progress.hasStarted,
               navigator.freshLocation(), !navigator.isRecalculating {
                Button("Route from my location", systemImage: "arrow.triangle.2.circlepath") {
                    navigator.recalculate(returnToStart: false)
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(PausePathPalette.lime)
                .frame(minHeight: 44)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PausePathPalette.ink, in: RoundedRectangle(cornerRadius: 22))
        .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
    }
    private var maneuverSymbol: String {
        let instruction = navigator.currentInstruction.lowercased()
        if instruction.contains("u-turn") || instruction.contains("uturn") { return "arrow.uturn.up" }
        if instruction.contains("left") { return "arrow.turn.up.left" }
        if instruction.contains("right") { return "arrow.turn.up.right" }
        if navigator.state == .paused { return "pause.fill" }
        return "arrow.up"
    }
    private var upcomingRouteStop: (place: DiscoveredPlace, meters: Double)? {
        let index = navigator.progress.legIndex
        guard plan.stops.indices.contains(index), plan.legs.indices.contains(index),
              navigator.progress.paths.indices.contains(index) else { return nil }
        let legLength = WalkingGeometry.length(navigator.progress.paths[index])
        let traversed = legLength > 0 ? navigator.progress.metersAlongLeg / legLength * plan.legs[index].distance : 0
        return (plan.stops[index], max(0, plan.legs[index].distance - traversed))
    }
    private func mapControl(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.headline.weight(.bold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(PausePathPalette.surface, in: Circle())
        .overlay(Circle().strokeBorder(PausePathPalette.teal.opacity(0.15)))
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        .accessibilityLabel(label)
    }
    private var tripPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            Capsule().fill(PausePathPalette.teal.opacity(0.25)).frame(width: 34, height: 4).frame(maxWidth: .infinity)
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                let minutes = max(1, Int(ceil(navigator.remainingMeters / max(0.3, plan.preferences.speedMetersPerSecond) / 60)))
                let arrivalAvailable = navigator.state == .walking && navigator.freshLocation(at: timeline.date)
                let arrival = arrivalAvailable
                    ? timeline.date.addingTimeInterval(Double(minutes * 60)).formatted(date: .omitted, time: .shortened) : "—"
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        tripStat("Est. arrival", value: arrival)
                        tripStat("Time left", value: "\(minutes) min")
                        tripStat("Distance", value: distanceUnit.distance(navigator.remainingMeters))
                    }
                } else {
                    HStack(spacing: 8) {
                        tripStat("Est. arrival", value: arrival)
                        tripStat("Time left", value: "\(minutes) min")
                        tripStat("Distance", value: distanceUnit.distance(navigator.remainingMeters))
                    }
                }
            }
            ProgressView(value: min(navigator.progress.completedMeters, navigator.progress.totalMeters),
                         total: max(1, navigator.progress.totalMeters))
                .tint(PausePathPalette.lime)
            if let next = upcomingRouteStop {
                HStack(spacing: 9) {
                    if next.place.kind == .bench {
                        BenchSymbol().fill(next.place.kind.mapColor).frame(width: 18, height: 18)
                    } else {
                        Image(systemName: next.place.kind.symbol).foregroundStyle(next.place.kind.mapColor)
                    }
                    Text(next.place.item.name ?? next.place.kind.chipTitle).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(distanceUnit.nearby(next.meters)).fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.primary)
            } else if plan.stops.isEmpty {
                Text("No planned pause on this route").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button(navigator.state == .paused ? "Resume" : "Pause",
                       systemImage: navigator.state == .paused ? "play.fill" : "pause.fill") {
                    if navigator.state == .paused { navigator.start(); followsUser = true; lastCameraCoordinate = nil; updateNavigationCamera() }
                    else { navigator.pause() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(PausePathPalette.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 14))
                Button("Details", systemImage: "list.bullet") { showRouteDetails = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(PausePathPalette.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            }
            .font(.subheadline.weight(.bold))
            if navigator.locationPermissionDenied {
                Button("Allow location in Settings", systemImage: "location.slash") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.font(.caption)
            }
        }
        .padding(17)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 26))
        .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(PausePathPalette.teal.opacity(0.13)))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 5)
    }
    private func tripStat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(.title3, design: .rounded).weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.75).monospacedDigit()
                .foregroundStyle(.primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
    private var activeRouteDetails: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    navigationStatus
                    NextPauseCard(navigator: navigator)
                    RouteBreaksView(walk: plan, currentLocation: navigator.freshLocation() ? navigator.location?.coordinate : nil,
                        onDetour: { takingBreak = true; navigator.pause() }, onReturn: { takingBreak = false },
                        onStopsChanged: { suggestedStops = $0 })
                        .id(plan.id)
                    DisclosureGroup("All directions") {
                        ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                            Text("Leg \(index + 1)").font(.headline)
                            ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
                                if !step.instructions.isEmpty {
                                    Text("\(step.instructions) · \(distanceUnit.nearby(step.distance))")
                                        .font(.subheadline).padding(.vertical, 3)
                                }
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 20))
                }
                .padding(16)
            }
            .pausePathSurface()
            .navigationTitle("Walk details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showRouteDetails = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    private var routeReadyControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ROUTE PREVIEW")
                        .font(.caption2.weight(.heavy)).tracking(1.2)
                        .foregroundStyle(PausePathPalette.teal)
                    Text(plan.name)
                        .font(.title2.bold()).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button(savedRoute ? "Saved" : "Save", systemImage: savedRoute ? "heart.fill" : "heart") {
                    if var record = SavedRouteStore.saveWalk(plan) { record.isFavorite = true; SavedRouteStore.update(record); savedRoute = true }
                    else { saveMessage = "Route library full. Remove a saved route in Profile." }
                }
                .disabled(savedRoute)
                .buttonStyle(.bordered)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                previewMetric("Distance", value: distanceUnit.distance(plan.distance), icon: "point.topleft.down.to.point.bottomright.curvepath")
                previewMetric("Estimated time", value: "\(max(1, Int(ceil(plan.duration / 60)))) min", icon: "clock")
                previewMetric("Planned pauses", value: "\(plan.stops.count)", icon: "bench")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(restStatusTitle, systemImage: plan.restAssessment.status == .meets ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Longest gap: \(plan.restAssessment.longestGap.map { distanceUnit.nearby($0) } ?? "Unknown") · your maximum: \(distanceUnit.nearby(plan.preferences.maximumRestGapMeters))")
                    .font(.caption)
            }
            .foregroundStyle(PausePathPalette.teal)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .padding(.horizontal, 12)
            .background(plan.restAssessment.status == .meets ? PausePathPalette.lime.opacity(0.24) : PausePathPalette.teal.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 13))
            Label("Terrain: unknown", systemImage: "mountain.2")
                .font(.caption).foregroundStyle(.secondary)
            if !saveMessage.isEmpty { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(PausePathPalette.teal.opacity(0.10)))
    }

    private var restStatusTitle: String {
        switch plan.restAssessment.status {
        case .meets: "Mapped rest gap meets your preference"
        case .unverified: "Gap fits · stop availability unverified"
        case .exceeds: "Rest gap exceeds your preference"
        case .unknown: "Rest gap could not be verified"
        }
    }

    private func previewMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if icon == "bench" {
                    BenchSymbol().fill(PausePathPalette.teal).frame(width: 14, height: 14)
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
                .font(.caption2.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
                .lineLimit(2)
            Text(value).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
        .padding(8)
        .background(PausePathPalette.background, in: RoundedRectangle(cornerRadius: 13))
        .accessibilityElement(children: .combine)
    }

    private var previewTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Stops along the way")
                .font(.headline).foregroundStyle(PausePathPalette.teal)
                .padding(.bottom, 12)
            timelineRow("Start", detail: "Your chosen starting point", icon: "location.fill", color: PausePathPalette.teal, isLast: false)
            ForEach(Array(plan.stops.enumerated()), id: \.offset) { index, stop in
                let distance = plan.legs.prefix(index + 1).reduce(0) { $0 + $1.distance }
                let arrival = plan.preferences.departure.addingTimeInterval(distance / max(0.3, plan.preferences.speedMetersPerSecond) + Double(index) * 300)
                timelineRow(stop.item.name ?? stop.kind.chipTitle,
                            detail: "\(distanceUnit.nearby(distance)) from start · \(stop.shared?.availabilityDescription(at: arrival) ?? "Hours at arrival unknown")",
                            note: "Last community check: \(stop.shared?.verificationDescription ?? "Unknown")",
                            icon: stop.kind == .bench ? "bench" : stop.kind.symbol, color: stop.kind.mapColor, isLast: false)
            }
            timelineRow("Finish", detail: plan.stops.isEmpty ? "Direct route · no planned pauses" : "After \(plan.stops.count) planned pauses",
                        icon: "flag.fill", color: PausePathPalette.teal, isLast: true)
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 24))
    }

    private var previewDetails: some View {
        DisclosureGroup("Terrain & route details") {
            Text("Terrain, surface, and stairs are unknown unless route data provides them.")
                .font(.caption).foregroundStyle(.secondary)
            RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: plan.distance, durationSeconds: plan.duration))
            RestGapStatusCard(assessment: plan.restAssessment, limit: plan.preferences.maximumRestGapMeters)
            Text(plan.requirements).font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(17)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func timelineRow(_ title: String, detail: String, note: String? = nil, icon: String, color: Color, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Group {
                    if icon == "bench" {
                        BenchSymbol().fill(.white).frame(width: 18, height: 18)
                    } else {
                        Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: 34, height: 34).background(color, in: Circle())
                if !isLast { Rectangle().fill(PausePathPalette.teal.opacity(0.18)).frame(width: 2, height: 38) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
                    Text("In \(distanceUnit.nearby(step.meters))").foregroundStyle(.secondary)
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
            Text("\(distanceUnit.distance(navigator.remainingMeters)) left · \(max(1, Int(navigator.remainingMeters / max(0.3, plan.preferences.speedMetersPerSecond) / 60))) min")
                .font(.subheadline.weight(.semibold))
            if navigator.remainingRestAssessment.status == .exceeds {
                Label("Next rest gap exceeds your preference", systemImage: "exclamationmark.circle").font(.caption)
            }
            DisclosureGroup("Route details") {
                RestGapStatusCard(assessment: navigator.remainingRestAssessment, limit: plan.preferences.maximumRestGapMeters)
            }.font(.subheadline)
            if navigator.state != .arrived {
                if navigator.locationPermissionDenied {
                    Button("Allow location in Settings", systemImage: "location.slash") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.buttonStyle(.bordered)
                }
                if navigator.state == .locating { ProgressView("Finding your location…") }
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
            milestoneMessage = "A new distance PR! " + distanceUnit.distance(distance, digits: 2) + ". See your milestones in My Path."
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
            let distanceText = distanceUnit.nearby(distance)
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
