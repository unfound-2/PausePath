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
    @AppStorage(DistanceDisplayUnit.storageKey) private var distanceUnitRaw = DistanceDisplayUnit.kilometers.rawValue
    private var distanceUnit: DistanceDisplayUnit { DistanceDisplayUnit(rawValue: distanceUnitRaw) ?? .kilometers }

    let discovery: PlaceDiscovery
    let preferences: RoutePreferences
    let profile: PausePathProfile
    let health: HealthActivityStore
    let initialDestination: DiscoveredPlace?
    @Binding var destinationQuery: String
    @Binding var destination: MKMapItem?
    @Binding var mandatoryKinds: Set<FacilityKind>
    @Binding var difficultyFilter: RoutePlannerDifficultyFilter
    @Binding var routeRequestID: UUID
    let usesCurrentLocation: Bool
    let customOrigin: CLLocationCoordinate2D?
    let customOriginName: String
    let planningControls: AnyView
    let chosenStops: [DiscoveredPlace]
    let onNavigate: (GeneratedWalk) -> Void

    let onClose: () -> Void
    @State private var status = "Choose an end destination to find walking routes."
    @State private var savedRouteCount = SavedRouteStore.load().count
    @State private var showHelp = false
    @State private var showWeather = false
    @State private var showRestPreferences = false
    @State private var sortOrder: RouteSortOrder = .recommended
    @State private var lastBuiltRequestID: UUID?
    @State private var requestedRestGap = 400.0
    @State private var allowUnknownRestStops = true
    @State private var routeTask: Task<Void, Never>?
    @State private var routeWeather = WeatherGuidanceStore()
    @State private var dismissedSuggestionID: String?
    @AppStorage("pausepath.trackedWalks") private var trackedData = Data()
    @AppStorage("pausepath.walkFeedback") private var feedbackData = Data()
    @AppStorage("pausepath.hiddenHealthWorkouts") private var hiddenHealthData = Data()
    @AppStorage("pausepath.demoMode") private var demoMode = false
    @AppStorage("pausepath.weather.openMeteo.guidance.enabled") private var weatherGuidanceEnabled = true
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

    private var routePreferences: RoutePreferences {
        var value = preferences
        value.maximumRestGapMeters = requestedRestGap
        value.facilities.formUnion(mandatoryKinds)
        return value
    }
    private var originTitle: String { usesCurrentLocation ? "Current location" : customOriginName }

    private var walkingHistory: [WalkingHistoryEntry] {
        if demoMode { return WalkingHistoryBuilder.sample() }
        let tracked = (try? JSONDecoder().decode([TrackedWalk].self, from: trackedData)) ?? []
        let feedback = (try? JSONDecoder().decode([WalkFeedback].self, from: feedbackData)) ?? []
        let hidden = (try? JSONDecoder().decode(Set<String>.self, from: hiddenHealthData)) ?? []
        let workouts = health.activities.filter { $0.kind == "Walking" && !hidden.contains($0.id) }
            .map { HealthWalkingRecord(id: $0.id, start: $0.date, seconds: $0.seconds, distanceMeters: $0.meters) }
        return WalkingHistoryBuilder.combine(tracked: tracked, health: workouts, feedback: feedback)
    }

    private var rankingResult: RouteRankingResult {
        let features = discovery.routeOptions.map { option in
            let rest = option.restAssessment(routePreferences, allowUnknown: allowUnknownRestStops)
            var confirmedBenches = 0
            var availableKinds = Set<FacilityKind>()
            var confirmedKinds = Set<FacilityKind>()
            var distance = 0.0
            for (index, stop) in option.stops.enumerated() {
                if index < option.legs.count { distance += option.legs[index].distance }
                let arrival = routePreferences.departure.addingTimeInterval(distance / max(0.3, routePreferences.speedMetersPerSecond) + Double(index) * 300)
                let poi = stop.shared
                let usable = poi?.restrictedAccess != true && poi?.unavailable != true &&
                    poi?.reportedUnavailable != true && poi?.openAtArrival(arrival) != false
                if usable { availableKinds.insert(stop.kind) }
                if usable && poi?.openAtArrival(arrival) == true && poi?.accessDescription == "public" {
                    confirmedKinds.insert(stop.kind)
                    if stop.kind == .bench { confirmedBenches += 1 }
                }
            }
            let required = routePreferences.facilities
            let availability: Bool? = required.isEmpty ? true :
                !required.isSubset(of: availableKinds) ? false : required.isSubset(of: confirmedKinds) ? true : nil
            return RouteFeatureSnapshot(id: option.id.uuidString, distanceMeters: option.distance, estimatedSeconds: option.duration,
                confirmedRestPoints: confirmedBenches, requiredFacilitiesAvailable: availability,
                longestRestGapMeters: rest.longestGap, restStatus: rest.status, facilityKinds: availableKinds)
        }
        return PersonalRouteRanker.evaluate(features, preferences: routePreferences, history: walkingHistory)
    }
    private var rankedSuggestions: [RouteSuggestion] { rankingResult.suggestions }

    private var visibleOptions: [WalkingRouteOption] {
        let selectedPreferences = routePreferences
        let includeUnknown = allowUnknownRestStops
        let positions = Dictionary(uniqueKeysWithValues: rankedSuggestions.enumerated().map { ($0.element.routeID, $0.offset) })
        let filtered = difficultyFilter.level.map { level in discovery.routeOptions.filter { difficulty(of: $0) == level } } ?? discovery.routeOptions
        return filtered.sorted { left, right in
            switch sortOrder {
            case .recommended:
                let leftPosition = positions[left.id.uuidString]
                let rightPosition = positions[right.id.uuidString]
                if let leftPosition, let rightPosition { return leftPosition < rightPosition }
                if leftPosition != nil { return true }
                if rightPosition != nil { return false }
                func restRank(_ option: WalkingRouteOption) -> Int {
                    switch option.restAssessment(selectedPreferences, allowUnknown: includeUnknown).status {
                    case .meets: 0; case .unverified: 1; case .exceeds: 2; case .unknown: 3
                    }
                }
                if restRank(left) != restRank(right) { return restRank(left) < restRank(right) }
                let leftMatches = selectedPreferences.facilities.intersection(Set(left.stops.map(\.kind))).count
                let rightMatches = selectedPreferences.facilities.intersection(Set(right.stops.map(\.kind))).count
                if leftMatches != rightMatches { return leftMatches > rightMatches }
                let leftDifference = abs(left.distance - selectedPreferences.distanceMeters)
                let rightDifference = abs(right.distance - selectedPreferences.distanceMeters)
                if leftDifference != rightDifference { return leftDifference < rightDifference }
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Plan your walk").font(.title3.bold()).foregroundStyle(PausePathPalette.teal)
                    Text("From \(originTitle)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
                        .frame(width: 44, height: 44).background(.quaternary, in: Circle())
                }.accessibilityLabel("Collapse route options and return to map")
            }.padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 8)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if discovery.routeOptions.isEmpty { planningControls }
                    else { DisclosureGroup("Change start or destination") { planningControls } }
                    DisclosureGroup(isExpanded: $showRestPreferences) {
                        Stepper("Rest gap: \(distanceUnit.nearby(requestedRestGap))", value: $requestedRestGap, in: 100...1000, step: 50)
                        Toggle("Include benches with unknown hours or access", isOn: $allowUnknownRestStops)
                        Text("Closed and restricted benches are excluded. Unknown availability stays marked.").font(.caption).foregroundStyle(.secondary)
                        Button("Update choices") { requestRoutes(for: UUID()) }.disabled(discovery.isLoading || destination == nil)
                    } label: {
                        HStack(spacing: 8) {
                            BenchSymbol().fill(PausePathPalette.teal).frame(width: 18, height: 18)
                            Text("Rest stops · \(distanceUnit.nearby(requestedRestGap))")
                                .font(.subheadline.weight(.semibold))
                        }
                    }.padding(14).background(PausePathPalette.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                    if discovery.isLoading { ProgressView("Finding routes…") }
                    else if !status.isEmpty {
                        if discovery.routeOptions.isEmpty { Text(status).font(.callout).foregroundStyle(.secondary) }
                        else { DisclosureGroup("Search notes") { Text(status).font(.caption).foregroundStyle(.secondary) } }
                    }
                    if !discovery.routeOptions.isEmpty {
                        routeFilters
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
                                Text("Required stops unavailable. Other routes below.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(requiredOptions) { routeRow($0) }
                            if !otherOptions.isEmpty {
                                Text("Other routes").font(.subheadline.weight(.semibold))
                                Text("Some required stops are missing.").font(.caption).foregroundStyle(.secondary)
                                ForEach(otherOptions) { routeRow($0) }
                            }
                        } else {
                            ForEach(visibleOptions) { routeRow($0) }
                        }
                        Button("How route estimates work", systemImage: "info.circle") { showHelp = true }
                            .font(.caption)
                    } else if let destination {
                        Text("Destination: \(destination.name ?? destinationQuery)").font(.subheadline.weight(.semibold))
                        if discovery.isLoading { ProgressView("Finding routes…") }
                        else {
                            Text("Choose a starting point and review route options for this destination.")
                                .font(.callout).foregroundStyle(.secondary)
                            Button("Find routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                                requestRoutes(for: UUID())
                            }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink)
                                .disabled(originCoordinate == nil)
                        }
                    } else {
                        Label("Choose a destination above or on the map.", systemImage: "magnifyingglass")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .onAppear {
                if lastBuiltRequestID == nil { requestedRestGap = preferences.maximumRestGapMeters }
                if destination == nil, let initialDestination {
                    destination = initialDestination.item
                    destinationQuery = initialDestination.item.name ?? "Selected place"
                }
                if usesCurrentLocation && !isFresh(discovery.currentLocation) { discovery.useLocation() }
                if destination != nil { requestRoutes(for: routeRequestID) }
            }
            .onChange(of: routeRequestID) { _, requestID in requestRoutes(for: requestID) }
            .onChange(of: destination?.name) {
                if destination != nil { requestRoutes(for: UUID()) }
            }
            .sheet(isPresented: $showWeather) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if weatherGuidanceEnabled { WeatherGuidanceCard(store: routeWeather) }
                            else { Button("Check weather") { weatherGuidanceEnabled = true }.buttonStyle(.borderedProminent) }
                            Text("Forecast for the selected route. Weather preferences are in Account settings.").font(.caption).foregroundStyle(.secondary)
                        }.padding(20)
                    }.pausePathSurface().navigationTitle("Weather").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showWeather = false } } }
                }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showHelp) {
                NavigationStack {
                    List {
                        Section("Location and privacy") {
                            Text("PausePath uses your current location to find nearby destinations and possible stops, calculate walking routes, and show live progress while you navigate. Location is not used for advertising or community tracking. Route details are saved on this device. Weather guidance is on by default and sends approximate route points to Open-Meteo; turn it off in Account settings any time.")
                            Text("An explicitly started walk can continue with the phone locked when location permission is available. End navigation to stop tracking. You can change permission in Settings.")
                        }
                        Section("Route choices") {
                            Text("Difficulty is a planning estimate based on route details that are available, such as distance and estimated time. It is not a judgment of your fitness.")
                            Text("Required stops appear first when mapped options include them. Place and amenity data can be incomplete, and opening or accessibility details may be out of date.")
                        }
                    }.pausePathSurface()
        .navigationTitle("About route planning")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
                }.presentationDetents([.medium, .large])
            }
            .onChange(of: discovery.currentLocation?.timestamp) {
                if isFresh(discovery.currentLocation) && discovery.routeOptions.isEmpty && !discovery.isLoading {
                    status = "Starting point: your current location."
                    if destination != nil { requestRoutes(for: UUID()) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PausePathPalette.background)
        .onDisappear { routeTask?.cancel() }
        .task(id: "\(discovery.selectedRouteOptionID?.uuidString ?? "none")-\(weatherGuidanceEnabled)-\(showWeather)") {
            guard showWeather, weatherGuidanceEnabled,
                  let option = discovery.routeOptions.first(where: { $0.id == discovery.selectedRouteOptionID }) else {
                routeWeather.clear()
                return
            }
            await routeWeather.load(for: GeneratedWalk(name: option.title, legs: option.legs, preferences: preferences))
        }
    }

    private var routeFilters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(visibleOptions.count) route options").font(.subheadline.weight(.semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { difficultyMenu; sortMenu }
                VStack(alignment: .leading, spacing: 8) { difficultyMenu; sortMenu }
            }
        }
    }

    private var difficultyMenu: some View {
        Menu {
            ForEach(RoutePlannerDifficultyFilter.allCases) { filter in
                Button { difficultyFilter = filter } label: {
                    if filter == difficultyFilter { Label(filter.rawValue, systemImage: "checkmark") }
                    else { Text(filter.rawValue) }
                }
            }
        } label: {
            Label("Difficulty: \(difficultyFilter.rawValue)", systemImage: "line.3.horizontal.decrease")
                .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(RouteSortOrder.allCases) { order in
                Button { sortOrder = order } label: {
                    if order == sortOrder { Label(order.rawValue, systemImage: "checkmark") }
                    else { Text(order.rawValue) }
                }
            }
        } label: {
            Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Sort routes: \(sortOrder.rawValue)")
    }

    @ViewBuilder private func routeRow(_ option: WalkingRouteOption) -> some View {
        let isSelected = option.id == discovery.selectedRouteOptionID
        let missing = mandatoryKinds.subtracting(Set(option.stops.map(\.kind))).map(\.chipTitle).sorted()
        let restAssessment = option.restAssessment(routePreferences, allowUnknown: allowUnknownRestStops)
        VStack(alignment: .leading, spacing: 12) {
            Button { discovery.selectRouteOption(option.id) } label: {
                VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.gray)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(option.stops.isEmpty ? "Direct route" : "Route with \(option.stops.count) stops").font(.headline).foregroundStyle(.primary)
                        if profileMatches(option) {
                            Label("Matches your preferences", systemImage: "checkmark.circle")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                    routeMetric("Distance", value: distanceUnit.distance(option.distance))
                    routeMetric("Est. time", value: "\(max(1, Int(ceil(option.distance / max(0.3, routePreferences.speedMetersPerSecond) / 60)))) min")
                    routeMetric("Planned stops", value: "\(option.stops.count)")
                }
                Label(restBadgeTitle(restAssessment.status),
                      systemImage: restAssessment.status == .meets ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PausePathPalette.teal)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityHint("Preview this route on the map")
            if !missing.isEmpty {
                Text("Does not include: \(missing.joined(separator: ", "))")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if isSelected {
                RestGapStatusCard(assessment: restAssessment, limit: requestedRestGap)
                Label("Access & terrain may be unverified", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Weather", systemImage: "cloud.sun") { showWeather = true }.font(.subheadline)
                    Spacer()
                }.frame(minHeight: 44)
                DisclosureGroup("Route details") {
                    RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration), compact: true)
                    if !option.stops.isEmpty {
                        Text(option.stops.map { $0.item.name ?? $0.kind.rawValue }.joined(separator: " → ")).font(.caption)
                    }
                    if let suggestion = rankedSuggestions.first(where: { $0.routeID == option.id.uuidString }) {
                        Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }.font(.subheadline)
            Button("Preview walk", systemImage: "figure.walk") {
                let walk = GeneratedWalk(name: "Walk to \(option.destinationName)", legs: option.legs, preferences: routePreferences, stops: option.stops, allowUnknownRestStops: allowUnknownRestStops)
                onClose()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    onNavigate(walk)
                }
            }.buttonStyle(.borderedProminent).tint(PausePathPalette.lime).foregroundStyle(PausePathPalette.ink).controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isSelected ? PausePathPalette.teal : PausePathPalette.teal.opacity(0.10), lineWidth: isSelected ? 2 : 1)
        }
    }

    private func restBadgeTitle(_ status: RestGapAssessment.Status) -> String {
        switch status {
        case .meets: "Mapped rest gap meets your preference"
        case .unverified: "Rest gap fits · stops unverified"
        case .exceeds: "Rest gap exceeds your preference"
        case .unknown: "Rest gap unknown"
        }
    }

    private func routeMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PausePathPalette.background, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func buildRoutes() async {
        guard let origin = originCoordinate, let destination else { return }
        guard !Task.isCancelled else { return }
        clearRouteOptions()
        status = "Looking for stops near the route…"
        let region = corridorRegion(from: origin, to: destination.placemark.coordinate)
        _ = await discovery.discover(kinds: Set(FacilityKind.allCases), region: region, waitForRefresh: true, maxRefreshAttempts: 1)

        guard !Task.isCancelled else { return }
        let allPlaces = discovery.places
        let corridorPlaces = allPlaces
            .map { (place: $0, distance: distanceFromDirectLine($0.item.placemark.coordinate, from: origin, to: destination.placemark.coordinate)) }
            .filter { $0.distance <= 1_200 }
            .sorted { $0.distance < $1.distance }
            .map { $0.place }

        var candidates = chosenStops.filter { stop in
            CLLocation(latitude: stop.item.placemark.coordinate.latitude, longitude: stop.item.placemark.coordinate.longitude).distance(from: CLLocation(latitude: destination.placemark.coordinate.latitude, longitude: destination.placemark.coordinate.longitude)) > 15
        }
        if mandatoryKinds.isEmpty {
            for kind in [FacilityKind.bench, .bathroom, .fountain, .cafe] {
                if candidates.count < 3, let candidate = corridorPlaces.first(where: { place in place.kind == kind && !candidates.contains(where: { $0.id == place.id }) }) {
                    candidates.append(candidate)
                }
            }
            for candidate in corridorPlaces where candidates.count < 3 && !candidates.contains(where: { $0.id == candidate.id }) { candidates.append(candidate) }
        } else {
            for kind in mandatoryKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
                if candidates.count < 3, !candidates.contains(where: { $0.kind == kind }), let candidate = corridorPlaces.first(where: { $0.kind == kind }) { candidates.append(candidate) }
            }
            for candidate in corridorPlaces where candidates.count < 3 && !candidates.contains(where: { $0.id == candidate.id }) {
                candidates.append(candidate)
            }
        }

        status = "Building direct and stop-based route options…"
        await discovery.walkingDirections(to: destination, destinationName: destination.name ?? destinationQuery, from: origin, via: candidates, preferences: routePreferences, allowUnknownRestStops: allowUnknownRestStops)
        guard !Task.isCancelled else { return }
        let chosenIDs = Set(candidates.filter { candidate in chosenStops.contains(where: { $0.id == candidate.id }) }.map(\.id))
        if !chosenIDs.isEmpty {
            discovery.routeOptions.removeAll { !chosenIDs.isSubset(of: Set($0.stops.map(\.id))) }
            if let first = discovery.routeOptions.first { discovery.selectRouteOption(first.id) }
            else { discovery.route = nil; discovery.itinerary = []; discovery.selectedRouteOptionID = nil }
        }
        if discovery.routeOptions.isEmpty {
            status = mandatoryKinds.isEmpty
                ? "No walking route was found. Try another destination or start."
                : "No route options were found. Some selected stop types may not have mapped locations near this route."
            return
        }
        let availableKinds = Set(candidates.map(\.kind))
        let unavailable = mandatoryKinds.subtracting(availableKinds)
        let unmet = discovery.routeOptions.allSatisfy { $0.restAssessment(routePreferences, allowUnknown: allowUnknownRestStops).status == .exceeds }
        let gapWarning = unmet ? "No route meets your requested rest gap with the available mapped data. Choose another destination, a shorter walk, or change your preference." : ""
        let unavailableText = unavailable.isEmpty ? "" : " No mapped \(unavailable.map(\.chipTitle).sorted().joined(separator: " or ")) was found near the route."
        let onlyDirect = discovery.routeOptions.allSatisfy { $0.stops.isEmpty }
        let explanation = onlyDirect ? (discovery.areaLoadState == "ready"
            ? "Only routes without planned stops could be built. Try a different destination or add a mapped stop."
            : "Facility data is still incomplete. These routes have no planned stops; update choices when stops finish loading.") : ""
        status = ([gapWarning, unavailableText, explanation].filter { !$0.isEmpty }).joined(separator: " ")
        savedRouteCount = SavedRouteStore.load().count
    }

    private func requestRoutes(for requestID: UUID) {
        guard lastBuiltRequestID != requestID else { return }
        lastBuiltRequestID = requestID
        routeTask?.cancel()
        routeTask = Task { await buildRoutes() }
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
        let restStatus = option.restAssessment(routePreferences, allowUnknown: allowUnknownRestStops).status
        return withinDistance && matchesStops && withinGentleRange && (restStatus == .meets || restStatus == .unverified)
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
