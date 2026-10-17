import SwiftUI
import MapKit
import CoreLocation

enum RoutePlannerDifficultyFilter: String, CaseIterable, Identifiable {
    case all = "Any"
    case easy = "Easy"
    case moderate = "Moderate"
    case hard = "Hard"
    var id: String { rawValue }
    var level: RouteDifficultyLevel? {
        switch self {
        case .all: nil
        case .easy: .easy
        case .moderate: .moderate
        case .hard: .hard
        }
    }
}

@MainActor
struct ExploreRoutePlannerView: View {
    let discovery: PlaceDiscovery
    let preferences: RoutePreferences
    let profile: PausePathProfile
    let initialDestination: DiscoveredPlace?
    @Binding var destinationQuery: String
    @Binding var destination: MKMapItem?
    @Binding var mandatoryKinds: Set<FacilityKind>
    @Binding var difficultyFilter: RoutePlannerDifficultyFilter
    @Binding var routeRequestID: UUID
    let usesCurrentLocation: Bool
    let customOrigin: CLLocationCoordinate2D?
    let customOriginName: String
    let onNavigate: (GeneratedWalk) -> Void

    let onClose: () -> Void
    @State private var status = "Choose an end destination to find walking routes."
    @State private var savedRouteCount = SavedRouteStore.load().count
    @State private var showHelp = false
    @State private var sortOrder: RouteSortOrder = .recommended
    @State private var lastBuiltRequestID: UUID?
    @AppStorage(RouteDifficultyPreferences.storageKey)
    private var factorSelection = RouteDifficultyPreferences.defaultStorageValue

    private enum RouteSortOrder: String, CaseIterable, Identifiable {
        case recommended = "Recommended"
        case easiest = "Easiest first"
        case hardest = "Hardest first"
        case fewestStops = "Fewest stops"
        case mostStops = "Most stops"
        case shortest = "Shortest"
        case longest = "Longest"
        var id: String { rawValue }
    }

    private var originCoordinate: CLLocationCoordinate2D? {
        usesCurrentLocation ? (isFresh(discovery.currentLocation) ? discovery.currentLocation?.coordinate : nil) : customOrigin
    }

    private var originTitle: String { usesCurrentLocation ? "Current location" : customOriginName }

    private var visibleOptions: [WalkingRouteOption] {
        let filtered = difficultyFilter.level.map { level in discovery.routeOptions.filter { difficulty(of: $0) == level } } ?? discovery.routeOptions
        return filtered.sorted { left, right in
            switch sortOrder {
            case .recommended:
                let leftRecommended = profileMatches(left)
                let rightRecommended = profileMatches(right)
                if leftRecommended != rightRecommended { return leftRecommended }
                return left.duration < right.duration
            case .easiest: return (sortRank(difficulty(of: left)), left.duration) < (sortRank(difficulty(of: right)), right.duration)
            case .hardest: return (sortRank(difficulty(of: left)), left.duration) > (sortRank(difficulty(of: right)), right.duration)
            case .fewestStops: return left.stops.count == right.stops.count ? left.duration < right.duration : left.stops.count < right.stops.count
            case .mostStops: return left.stops.count == right.stops.count ? left.duration < right.duration : left.stops.count > right.stops.count
            case .shortest: return left.distance == right.distance ? left.duration < right.duration : left.distance < right.distance
            case .longest: return left.distance == right.distance ? left.duration < right.duration : left.distance > right.distance
            }
        }
    }

    private var requiredOptions: [WalkingRouteOption] {
        visibleOptions.filter { option in mandatoryKinds.isSubset(of: Set(option.stops.map(\.kind))) }
    }

    private var otherOptions: [WalkingRouteOption] {
        visibleOptions.filter { option in !mandatoryKinds.isSubset(of: Set(option.stops.map(\.kind))) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 38, height: 5).padding(.top, 8).padding(.bottom, 3)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Route options").font(.headline)
                    Text("From \(originTitle)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40).background(.quaternary, in: Circle())
                }.accessibilityLabel("Collapse route options and return to map")
            }.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
                .contentShape(Rectangle())
                .simultaneousGesture(DragGesture(minimumDistance: 25).onEnded { value in
                    if value.translation.height > 65 { onClose() }
                })
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if usesCurrentLocation {
                        if originCoordinate == nil {
                            Label("Getting your location…", systemImage: "location.slash").font(.caption).foregroundStyle(.secondary)
                            Button("Try location again", systemImage: "location.fill") { discovery.useLocation() }.buttonStyle(.bordered)
                        } else {
                            Label("Using your current device location", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(customOriginName.isEmpty ? "Choose a starting place above" : "Starting at \(customOriginName)", systemImage: "location.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if !status.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
                    if !discovery.routeOptions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Routes").font(.headline)
                            HStack {
                                Menu {
                                ForEach(RoutePlannerDifficultyFilter.allCases) { filter in
                                    Button { difficultyFilter = filter } label: {
                                        if filter == difficultyFilter { Label(filter.rawValue, systemImage: "checkmark") } else { Text(filter.rawValue) }
                                    }
                                }
                                } label: {
                                    Label("Difficulty: \(difficultyFilter.rawValue)", systemImage: "line.3.horizontal.decrease")
                                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(.thinMaterial, in: Capsule())
                                }
                                Menu {
                                    ForEach(RouteSortOrder.allCases) { order in
                                        Button { sortOrder = order } label: {
                                            if order == sortOrder { Label(order.rawValue, systemImage: "checkmark") } else { Text(order.rawValue) }
                                        }
                                    }
                                } label: {
                                    Label("Sort", systemImage: "arrow.up.arrow.down")
                                        .font(.subheadline.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(.thinMaterial, in: Capsule())
                                }
                            }
                        }
                        if !visibleOptions.isEmpty && (difficultyFilter != .all || !mandatoryKinds.isEmpty) {
                            Button("Clear route filters") {
                                difficultyFilter = .all
                                mandatoryKinds = []
                            }.font(.caption.weight(.semibold))
                        }
                        if visibleOptions.isEmpty {
                            Label("No routes match these filters.", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Clear route filters") { difficultyFilter = .all; mandatoryKinds = [] }
                                .font(.subheadline.weight(.semibold))
                        } else if !mandatoryKinds.isEmpty {
                            Text("Routes with required stops").font(.subheadline.weight(.semibold))
                            if requiredOptions.isEmpty {
                                Text("No route includes all selected stop types. The other routes are listed below.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(requiredOptions) { routeRow($0) }
                            Text("Other routes without \(mandatoryKinds.map(\.chipTitle).sorted().joined(separator: ", "))")
                                .font(.subheadline.weight(.semibold))
                            Text("These routes may still work for you; each one names the stop types it misses.").font(.caption).foregroundStyle(.secondary)
                            ForEach(otherOptions) { routeRow($0) }
                        } else {
                            ForEach(visibleOptions) { routeRow($0) }
                        }
                        Text("Route choices are saved on this device for future comparison. \(savedRouteCount) saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let destination {
                        Text("Destination: \(destination.name ?? destinationQuery)").font(.subheadline.weight(.semibold))
                        if discovery.isLoading { ProgressView("Finding routes…") }
                        else {
                            Text("Choose a starting point and review route options for this destination.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Find routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                Task { await buildRoutes() }
                            }.buttonStyle(.borderedProminent)
                                .disabled(originCoordinate == nil)
                        }
                    } else {
                        Label("Search for a destination in the bar above to get started.", systemImage: "magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .onAppear {
                if destination == nil, let initialDestination {
                    destination = initialDestination.item
                    destinationQuery = initialDestination.item.name ?? "Selected place"
                }
                if usesCurrentLocation && !isFresh(discovery.currentLocation) { discovery.useLocation() }
                if destination != nil { requestRoutes(for: routeRequestID) }
            }
            .onChange(of: routeRequestID) { _, requestID in requestRoutes(for: requestID) }
            .onChange(of: destination?.name) {
                if destination != nil { Task { await buildRoutes() } }
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    List {
                        Section("Location and privacy") {
                            Text("PausePath uses your current location to find nearby destinations and possible stops, calculate walking routes, and show live progress while you navigate. Location is not used for advertising or community tracking. Route details are saved on this device. Weather checks share approximate route points only when you turn weather guidance on.")
                            Text("Live GPS runs only while an active walk is in the foreground. Tracking pauses when PausePath leaves the foreground and resumes only when you choose to resume the walk. iOS controls location permission and Precise Location; you can change both in Settings.")
                        }
                        Section("Route choices") {
                            Text("Difficulty is a planning estimate based on route details that are available, such as distance and estimated time. It is not a judgment of your fitness.")
                            Text("Required stops appear first when mapped options include them. Place and amenity data can be incomplete, and opening or accessibility details may be out of date.")
                        }
                    }.navigationTitle("About route planning")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: discovery.currentLocation?.timestamp) {
                if isFresh(discovery.currentLocation) { status = "Starting point: your current location." }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.5), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
    }

    @ViewBuilder private func routeRow(_ option: WalkingRouteOption) -> some View {
        let isSelected = option.id == discovery.selectedRouteOptionID
        let missing = mandatoryKinds.subtracting(Set(option.stops.map(\.kind))).map(\.chipTitle).sorted()
        VStack(alignment: .leading, spacing: 8) {
            Button { discovery.selectRouteOption(option.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.title).font(.headline).foregroundStyle(.primary)
                        if profileMatches(option) {
                            Label("Recommended for you", systemImage: "sparkles")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                        Text("\(option.distance / 1000, specifier: "%.1f") km • about \(Int(option.duration / 60)) min")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(difficulty(of: option)?.rawValue ?? "Rating unavailable")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(isSelected ? [.isSelected] : [])
            if !missing.isEmpty {
                Text("Does not include: \(missing.joined(separator: ", "))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration))
            Button("Navigate this route", systemImage: "figure.walk") {
                let walk = GeneratedWalk(name: "Walk to \(option.destinationName)", legs: option.legs, preferences: preferences)
                onClose()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    onNavigate(walk)
                }
            }.buttonStyle(.bordered)
        }.padding(.vertical, 6)
    }

    private func buildRoutes() async {
        guard let origin = originCoordinate, let destination else { return }
        clearRouteOptions()
        status = "Looking for stops near the route…"
        let region = corridorRegion(from: origin, to: destination.placemark.coordinate)
        _ = await discovery.discover(kinds: Set(FacilityKind.allCases), region: region)

        let allPlaces = discovery.places
        let corridorPlaces = allPlaces
            .map { (place: $0, distance: distanceFromDirectLine($0.item.placemark.coordinate, from: origin, to: destination.placemark.coordinate)) }
            .filter { $0.distance <= 1_200 }
            .sorted { $0.distance < $1.distance }
            .map { $0.place }

        var candidates: [DiscoveredPlace] = []
        if mandatoryKinds.isEmpty {
            candidates = Array(corridorPlaces.prefix(3))
        } else {
            for kind in mandatoryKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let candidate = corridorPlaces.first(where: { $0.kind == kind }) { candidates.append(candidate) }
            }
            for candidate in corridorPlaces where candidates.count < 3 && !candidates.contains(where: { $0.id == candidate.id }) {
                candidates.append(candidate)
            }
        }

        status = "Building direct and stop-based route options…"
        await discovery.walkingDirections(to: destination, destinationName: destination.name ?? destinationQuery, from: origin, via: candidates)
        if discovery.routeOptions.isEmpty {
            status = mandatoryKinds.isEmpty
                ? "No walking route was found. Try another destination or start."
                : "No route options were found. Some selected stop types may not have mapped locations near this route."
            return
        }
        let availableKinds = Set(candidates.map(\.kind))
        let unavailable = mandatoryKinds.subtracting(availableKinds)
        let unavailableText = unavailable.isEmpty ? "" : " No mapped \(unavailable.map(\.chipTitle).sorted().joined(separator: " or ")) was found near the route."
        status = "Routes found. Required stop matches appear first; other routes show which stop types they miss." + unavailableText
        savedRouteCount = SavedRouteStore.load().count
    }

    private func requestRoutes(for requestID: UUID) {
        guard lastBuiltRequestID != requestID else { return }
        lastBuiltRequestID = requestID
        Task { await buildRoutes() }
    }

    private func difficulty(of option: WalkingRouteOption) -> RouteDifficultyLevel? {
        RouteDifficultyCalculator.assess(
            RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration),
            preferences: RouteDifficultyPreferences(storageValue: factorSelection)
        ).rating
    }

    private func profileMatches(_ option: WalkingRouteOption) -> Bool {
        let withinDistance = abs(option.distance - preferences.distanceMeters) <= preferences.distanceMeters * 0.25
        let matchesStops = preferences.facilities.isEmpty || preferences.facilities.isSubset(of: Set(option.stops.map(\.kind)))
        let withinGentleRange = !profile.goal.prefersGentlerRoutes || difficulty(of: option) == .easy || difficulty(of: option) == .moderate
        return withinDistance && matchesStops && withinGentleRange
    }

    private func sortRank(_ level: RouteDifficultyLevel?) -> Int {
        switch level {
        case .easy: 0
        case .moderate: 1
        case .hard: 2
        case nil: 3
        }
    }

    private func clearRouteOptions() {
        discovery.route = nil
        discovery.itinerary = []
        discovery.routeOptions = []
        discovery.selectedRouteOptionID = nil
        status = "Update your choices and find routes again."
    }

    private func corridorRegion(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> MKCoordinateRegion {
        let latitudeDelta = max(0.015, abs(start.latitude - end.latitude) * 1.5)
        let longitudeDelta = max(0.015, abs(start.longitude - end.longitude) * 1.5)
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (start.latitude + end.latitude) / 2, longitude: (start.longitude + end.longitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: min(latitudeDelta, 0.3), longitudeDelta: min(longitudeDelta, 0.3))
        )
    }

    private func distanceFromDirectLine(_ point: CLLocationCoordinate2D, from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let latitudeScale = 111_000.0
        let longitudeScale = 111_000.0 * cos((start.latitude + end.latitude) / 2 * .pi / 180)
        let sx = start.longitude * longitudeScale, sy = start.latitude * latitudeScale
        let ex = end.longitude * longitudeScale, ey = end.latitude * latitudeScale
        let px = point.longitude * longitudeScale, py = point.latitude * latitudeScale
        let dx = ex - sx, dy = ey - sy
        let denominator = dx * dx + dy * dy
        let t = denominator == 0 ? 0 : min(1, max(0, ((px - sx) * dx + (py - sy) * dy) / denominator))
        return hypot(px - (sx + t * dx), py - (sy + t * dy))
    }

    private func isFresh(_ location: CLLocation?) -> Bool {
        guard let location else { return false }
        let age = Date().timeIntervalSince(location.timestamp)
        return location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 &&
            location.coordinate.latitude.isFinite && location.coordinate.longitude.isFinite &&
            (-90...90).contains(location.coordinate.latitude) && (-180...180).contains(location.coordinate.longitude) &&
            age.isFinite && age >= -2 && age <= 15
    }
}
