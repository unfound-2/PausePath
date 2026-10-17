import SwiftUI
import MapKit
import CoreLocation

@MainActor
struct ExploreRoutePlannerView: View {
    let discovery: PlaceDiscovery
    let preferences: RoutePreferences
    let initialDestination: DiscoveredPlace?
    let onNavigate: (GeneratedWalk) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var useCurrentLocation = true
    @State private var originQuery = ""
    @State private var customOrigin: CLLocationCoordinate2D?
    @State private var customOriginName = ""
    @State private var destinationQuery = ""
    @State private var destination: MKMapItem?
    @State private var selectedDestinationName = ""
    @State private var mandatoryKinds = Set<FacilityKind>()
    @State private var difficultyFilter: DifficultyFilter = .all
    @State private var status = "Choose an end destination to find walking routes."
    @State private var isSearching = false
    @State private var savedRouteCount = SavedRouteStore.load().count
    @AppStorage(RouteDifficultyPreferences.storageKey)
    private var factorSelection = RouteDifficultyPreferences.defaultStorageValue

    private enum DifficultyFilter: String, CaseIterable, Identifiable {
        case all = "All"
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

    private var originCoordinate: CLLocationCoordinate2D? {
        useCurrentLocation ? (isFresh(discovery.currentLocation) ? discovery.currentLocation?.coordinate : nil) : customOrigin
    }

    private var visibleOptions: [WalkingRouteOption] {
        guard let level = difficultyFilter.level else { return discovery.routeOptions }
        return discovery.routeOptions.filter { difficulty(of: $0) == level }
    }

    private var requiredOptions: [WalkingRouteOption] {
        visibleOptions.filter { option in mandatoryKinds.isSubset(of: Set(option.stops.map(\.kind))) }
    }

    private var otherOptions: [WalkingRouteOption] {
        visibleOptions.filter { option in !mandatoryKinds.isSubset(of: Set(option.stops.map(\.kind))) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Start at my current location", isOn: $useCurrentLocation)
                        .onChange(of: useCurrentLocation) { if useCurrentLocation { discovery.useLocation() } }
                        .disabled(discovery.isLoading || isSearching)
                    if useCurrentLocation {
                        Text(originCoordinate == nil ? "Waiting for a current location. Allow location access or choose a start address." : "Starting point: your current location")
                            .font(.caption).foregroundStyle(.secondary)
                        if originCoordinate == nil {
                            Button("Update my location", systemImage: "location.fill") { discovery.useLocation() }
                                .disabled(discovery.isLoading)
                        }
                    } else {
                        TextField("Starting address or place", text: $originQuery)
                            .textContentType(.fullStreetAddress)
                            .submitLabel(.search)
                            .onChange(of: originQuery) {
                                if customOrigin != nil && originQuery != customOriginName {
                                    customOrigin = nil
                                    clearRouteOptions()
                                }
                            }
                            .onSubmit { Task { await findPlace(originQuery, isOrigin: true) } }
                            .disabled(discovery.isLoading || isSearching)
                        Button(isSearching ? "Searching…" : "Set starting point", systemImage: "magnifyingglass") {
                            Task { await findPlace(originQuery, isOrigin: true) }
                        }.disabled(originQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching || discovery.isLoading)
                        if customOrigin != nil { Label("Start set", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    }
                } header: { Text("Starting point") }

                Section {
                    TextField("Address or place", text: $destinationQuery)
                        .textContentType(.fullStreetAddress)
                        .submitLabel(.search)
                        .onSubmit { Task { await findPlace(destinationQuery, isOrigin: false) } }
                        .onChange(of: destinationQuery) {
                            if selectedDestinationName != destinationQuery { destination = nil; selectedDestinationName = ""; clearRouteOptions() }
                        }
                        .disabled(discovery.isLoading || isSearching)
                    Button(isSearching ? "Searching…" : "Find destination", systemImage: "magnifyingglass") {
                        Task { await findPlace(destinationQuery, isOrigin: false) }
                    }.disabled(destinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching || discovery.isLoading)
                    if let destination {
                        Label("End: \(destination.name ?? destinationQuery)", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                    }
                    if let initialDestination {
                        Button("Use \(initialDestination.item.name ?? "selected map place")") {
                            destination = initialDestination.item
                            destinationQuery = initialDestination.item.name ?? "Selected place"
                            selectedDestinationName = destinationQuery
                        }
                    }
                } header: { Text("Destination") }

                Section {
                    Text("Optional: routes with every selected stop type appear first. Other routes remain available below with the missing stop types named.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(FacilityKind.allCases, id: \.self) { kind in
                        Toggle(kind.chipTitle, isOn: Binding(
                            get: { mandatoryKinds.contains(kind) },
                            set: { isOn in
                                if isOn {
                                    guard mandatoryKinds.count < 3 else { status = "Choose up to three required stop types."; return }
                                    mandatoryKinds.insert(kind)
                                } else { mandatoryKinds.remove(kind) }
                                clearRouteOptions()
                            }
                        )).disabled(discovery.isLoading)
                    }
                    Text("Mapped stops and opening hours may be incomplete. A listed stop is not a guarantee that it is open or accessible.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Stops to include") }

                Section {
                    Picker("Difficulty", selection: $difficultyFilter) {
                        ForEach(DifficultyFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                    }.pickerStyle(.segmented)
                    Button {
                        Task { await buildRoutes() }
                    } label: {
                        HStack {
                            if discovery.isLoading { ProgressView().controlSize(.small) }
                            Text(discovery.isLoading ? "Finding routes…" : "Find routes")
                        }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent)
                        .disabled(discovery.isLoading || isSearching || originCoordinate == nil || destination == nil)
                    Text("Routes use walking directions from Apple Maps. Estimated time can change with your pace and breaks.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Route choices") }

                if !discovery.routeOptions.isEmpty {
                    if !mandatoryKinds.isEmpty {
                        Section("Routes with required stops") {
                            if requiredOptions.isEmpty {
                                Text("No route found with every selected stop type. Check the other routes or change your selections.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(requiredOptions) { routeRow($0) }
                        }
                        Section {
                            Text("These options do not include every stop type you selected. Each route lists what it misses.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(otherOptions) { routeRow($0) }
                        } header: { Text("Other routes") }
                    } else {
                        Section("Suggested routes") {
                            ForEach(visibleOptions) { routeRow($0) }
                        }
                    }
                    Text("Route choices are saved on this device for future route history and comparison features. \(savedRouteCount) saved.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !status.isEmpty { Section { Text(status).font(.callout).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Plan a route")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear {
                if let initialDestination {
                    destination = initialDestination.item
                    destinationQuery = initialDestination.item.name ?? "Selected place"
                    selectedDestinationName = destinationQuery
                }
                if useCurrentLocation && !isFresh(discovery.currentLocation) { discovery.useLocation() }
            }
            .onChange(of: discovery.currentLocation?.timestamp) {
                if isFresh(discovery.currentLocation) { status = "Starting point: your current location." }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
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
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    onNavigate(walk)
                }
            }.buttonStyle(.bordered)
        }.padding(.vertical, 6)
    }

    private func findPlace(_ query: String, isOrigin: Bool) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleaned
        if let coordinate = originCoordinate {
            request.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let match = response.mapItems.first else { status = "No matching place found. Try a nearby street or landmark."; return }
            if isOrigin {
                originQuery = match.name ?? cleaned
                customOriginName = originQuery
                customOrigin = match.placemark.coordinate
            } else {
                destination = match
                destinationQuery = match.name ?? cleaned
                selectedDestinationName = destinationQuery
            }
            clearRouteOptions()
            status = "Place found. Review the route options before starting."
        } catch {
            status = "Place search is unavailable. Check your connection or try a different name."
        }
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

    private func difficulty(of option: WalkingRouteOption) -> RouteDifficultyLevel? {
        RouteDifficultyCalculator.assess(
            RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration),
            preferences: RouteDifficultyPreferences(storageValue: factorSelection)
        ).rating
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
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 100 && Date().timeIntervalSince(location.timestamp) <= 60
    }
}
