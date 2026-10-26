import SwiftUI
import MapKit
import CoreLocation
import UIKit

extension FacilityKind {
    var mapColor: Color {
        switch self {
        case .bench: Color(red: 0.08, green: 0.43, blue: 0.34)
        case .bathroom: Color(red: 0.38, green: 0.29, blue: 0.69)
        case .fountain: Color(red: 0.08, green: 0.43, blue: 0.75)
        case .cafe: Color(red: 0.65, green: 0.32, blue: 0.13)
        }
    }
    var chipTitle: String {
        switch self {
        case .bench: "Bench"
        case .bathroom: "Restroom"
        case .fountain: "Water"
        case .cafe: "Café"
        }
    }
}

struct DiscoverView: View {
    @AppStorage(DistanceDisplayUnit.storageKey) private var distanceUnitRaw = DistanceDisplayUnit.kilometers.rawValue
    private var distanceUnit: DistanceDisplayUnit { DistanceDisplayUnit(rawValue: distanceUnitRaw) ?? .kilometers }

    let preferences: RoutePreferences
    let profile: PausePathProfile
    let health: HealthActivityStore
    @State private var discovery = PlaceDiscovery()
    @State private var camera: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var usesCurrentRouteStart = true
    @State private var routeStartQuery = ""
    @State private var routeStartMatches: [MKMapItem] = []
    @State private var routeStart: MKMapItem?
    @State private var routeStartSearchTask: Task<Void, Never>?
    @State private var routeStartSearchInProgress = false
    @State private var currentLocationRequested = false
    @State private var routeStartSearchMessage = ""
    @State private var routeDestinationQuery = ""
    @State private var routeDestinationMatches: [MKMapItem] = []
    @State private var routeDestination: MKMapItem?
    @State private var routeSearchTask: Task<Void, Never>?
    @State private var routeSearchInProgress = false
    @State private var routeSearchMessage = ""
    @State private var routeDifficultyFilter = RoutePlannerDifficultyFilter.all
    @State private var mandatoryRouteStops = Set<FacilityKind>()
    @State private var routeRequestID = UUID()
    @State private var kinds = Set(FacilityKind.allCases)
    @State private var selectedID: UUID?
    @State private var showRoutePlanner = false
    @State private var sheetLevel = 0
    @GestureState private var sheetDrag: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var compactSheetHeight: CGFloat = 76
    @State private var browseQuery = ""
    @State private var browseMatches: [MKMapItem] = []
    @State private var browseTask: Task<Void, Never>?
    @State private var browseLoading = false
    @State private var browseMessage = ""
    @State private var pinnedStops: [DiscoveredPlace] = []
    @State private var didPositionMap = false
    @State private var navigationWalk: GeneratedWalk?
    @State private var searched = false
    @State private var showReport = false
    @State private var reportPlace: DiscoveredPlace?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var areaRefreshTask: Task<Void, Never>?
    @State private var lastRequestedRegion: MKCoordinateRegion?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visiblePlaces: [DiscoveredPlace] {
        let center = visibleRegion?.center ?? discovery.region.center
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        let bounds = visibleRegion ?? discovery.region
        return discovery.places.filter { place in
            let point = place.item.placemark.coordinate
            let delta = abs(point.longitude - bounds.center.longitude)
            return kinds.contains(place.kind) &&
                abs(point.latitude - bounds.center.latitude) <= bounds.span.latitudeDelta / 2 &&
                min(delta, 360 - delta) <= bounds.span.longitudeDelta / 2
        }.sorted {
            let left = CLLocation(latitude: $0.item.placemark.coordinate.latitude, longitude: $0.item.placemark.coordinate.longitude)
            let right = CLLocation(latitude: $1.item.placemark.coordinate.latitude, longitude: $1.item.placemark.coordinate.longitude)
            return left.distance(from: origin) < right.distance(from: origin)
        }
    }
    private struct StopCluster: Identifiable {
        let id: String
        let places: [DiscoveredPlace]
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: places.map { $0.item.placemark.coordinate.latitude }.reduce(0,+) / Double(places.count),
                                   longitude: places.map { $0.item.placemark.coordinate.longitude }.reduce(0,+) / Double(places.count))
        }
    }
    private var stopClusters: [StopCluster] {
        let region = visibleRegion ?? discovery.region
        let latStep = max(region.span.latitudeDelta / 6, 0.00001)
        let lonStep = max(region.span.longitudeDelta / 5, 0.00001)
        let displayed = visiblePlaces
        let grouped = Dictionary(grouping: displayed) { place in
            if displayed.count < 18 || place.id == selectedID { return place.id.uuidString }
            let c = place.item.placemark.coordinate
            return "\(Int(floor(c.latitude / latStep)))-\(Int(floor(c.longitude / lonStep)))"
        }
        return grouped.map { StopCluster(id: $0.key, places: $0.value) }.sorted { $0.id < $1.id }
    }
    private var selectedPlace: DiscoveredPlace? { visiblePlaces.first { $0.id == selectedID } }
    private var routeStartLocation: CLLocation? {
        if usesCurrentRouteStart { return isFresh(discovery.currentLocation) ? discovery.currentLocation : nil }
        guard let routeStart else { return nil }
        return routeStart.placemark.location ?? CLLocation(latitude: routeStart.placemark.coordinate.latitude, longitude: routeStart.placemark.coordinate.longitude)
    }
    private var routeStartCoordinate: CLLocationCoordinate2D? { routeStartLocation?.coordinate }
    private var routeStartTitle: String {
        if usesCurrentRouteStart { return "Current location" }
        if let name = routeStart?.name { return name }
        return routeStartQuery.isEmpty ? "Set my own" : routeStartQuery
    }

    var body: some View {
        GeometryReader { geometry in
            Map(position: $camera) {
                UserAnnotation()
                if !usesCurrentRouteStart, let start = routeStartCoordinate {
                    Annotation("Selected route start", coordinate: start, anchor: .bottom) {
                        Image(systemName: "location.fill")
                            .font(.headline).foregroundStyle(.white).frame(width: 42, height: 42)
                            .background(PausePathPalette.teal, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 4)
                            .accessibilityLabel("Selected route starting point")
                    }.annotationTitles(.hidden)
                }
                ForEach(stopClusters) { cluster in
                    let place = cluster.places[0]
                    Annotation(place.item.name ?? place.kind.rawValue, coordinate: cluster.coordinate, anchor: .bottom) {
                        Button {
                            if cluster.places.count == 1 { select(place) }
                            else {
                                let region = visibleRegion ?? discovery.region
                                camera = .region(MKCoordinateRegion(center: cluster.coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: region.span.latitudeDelta / 2, longitudeDelta: region.span.longitudeDelta / 2)))
                            }
                        } label: {
                            ZStack {
                                if cluster.places.count > 1 {
                                    Text("\(cluster.places.count)")
                                        .font(.caption.weight(.heavy))
                                        .foregroundStyle(PausePathPalette.ink)
                                        .frame(width: 34, height: 34)
                                        .background(PausePathPalette.lime, in: Circle())
                                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                                } else {
                                    Image(systemName: place.kind.symbol)
                                        .font(.system(size: selectedID == place.id ? 17 : 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: selectedID == place.id ? 40 : 31, height: selectedID == place.id ? 40 : 31)
                                        .background(place.kind.mapColor, in: Circle())
                                        .overlay(Circle().strokeBorder(selectedID == place.id ? PausePathPalette.lime : .white,
                                                                       lineWidth: selectedID == place.id ? 4 : 2))
                                }
                            }
                            .shadow(color: .black.opacity(selectedID == place.id ? 0.3 : 0.16), radius: selectedID == place.id ? 7 : 3, y: 2)
                            .frame(minWidth: 44, minHeight: 44)
                        }.buttonStyle(.plain)
                            .disabled(showRoutePlanner)
                            .accessibilityLabel(cluster.places.count > 1 ? "\(cluster.places.count) mapped stops. Zoom in to explore." : "\(place.item.name ?? "Possible stop"), \(place.kind.rawValue)")
                            .accessibilityHint("Show stop details and walking directions")
                            .accessibilityAddTraits(selectedID == place.id ? [.isSelected] : [])
                    }.annotationTitles(.hidden)
                }
                if discovery.route != nil {
                    ForEach(Array(discovery.itinerary.enumerated()), id: \.offset) { index, leg in
                        MapPolyline(leg.polyline).stroke(index == 0 ? PausePathPalette.teal : .blue, lineWidth: 6)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                if camera.positionedByUser { didPositionMap = true }
                // Programmatic camera changes (such as fitting a route) must not
                // replace the selected stop or erase its directions.
                guard camera.positionedByUser,
                      discovery.route == nil, !showReport, !showRoutePlanner, navigationWalk == nil else { return }
                scheduleAreaRefresh(context.region)
            }
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                if !showRoutePlanner { topControls }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Keep the selected route fitted in the map above the half sheet.
                if showRoutePlanner { Color.clear.frame(height: geometry.size.height * 0.5) }
            }
            .overlay(alignment: .bottom) {
                if !showRoutePlanner { bottomControls(availableHeight: geometry.size.height) }
            }
            .overlay(alignment: .bottom) {
                if !showRoutePlanner && sheetLevel == 0 && !searchFocused {
                    HStack(alignment: .bottom, spacing: 12) {
                        areaStatusOverlay
                        Spacer(minLength: 4)
                        mapQuickActions
                    }
                        .padding(.horizontal, 18)
                        .padding(.bottom, compactSheetHeight + 24)
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showRoutePlanner)
            .toolbarBackground(.hidden, for: .tabBar)
            .task {
                if !didPositionMap {
                    if discovery.showingSavedArea {
                        visibleRegion = discovery.region; camera = .region(discovery.region); didPositionMap = true
                        await loadArea(discovery.region)
                    } else { camera = .automatic }
                }
            }
            .task {
                // Preserve saved pins when returning to Explore.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard scenePhase == .active, !discovery.isLoading,
                          discovery.route == nil, selectedID == nil, !showReport, !showRoutePlanner, navigationWalk == nil else { continue }
                    await loadArea(visibleRegion ?? discovery.region)
                }
            }
            .sheet(isPresented: $showReport) {
                StopReportView(place: reportPlace,
                    coordinate: reportPlace?.item.placemark.coordinate ?? (visibleRegion ?? discovery.region).center) {
                    Task { await refresh() }
                }
            }
            .onChange(of: [discovery.region.center.latitude, discovery.region.center.longitude]) { moveToDiscoveredArea() }
            .onChange(of: discovery.currentLocation?.timestamp) { _, _ in
                guard let location = discovery.currentLocation, isFresh(location),
                      currentLocationRequested || (!didPositionMap && !camera.positionedByUser) else { return }
                currentLocationRequested = false
                didPositionMap = true
                let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1_400, longitudinalMeters: 1_400)
                visibleRegion = region
                camera = .region(region)
                Task { await loadArea(region) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .pausePathSavedAreasCleared)) { _ in discovery.clearAreaMemory() }
            .onDisappear {
                cancelAreaRefresh()
                routeStartSearchTask?.cancel()
                routeSearchTask?.cancel()
                browseTask?.cancel()
                browseLoading = false
                discovery.cancelPending()
            }
            .onChange(of: showRoutePlanner) { if showRoutePlanner { cancelAreaRefresh() } }
            .onChange(of: navigationWalk?.id) { if navigationWalk != nil { cancelAreaRefresh() } }
            .onChange(of: discovery.selectedRouteOptionID) { fitRouteInMap() }
            .sheet(isPresented: $showRoutePlanner) {
                ExploreRoutePlannerView(discovery: discovery, preferences: preferences, profile: profile, health: health, initialDestination: selectedPlace,
                    destinationQuery: $routeDestinationQuery, destination: $routeDestination,
                    mandatoryKinds: $mandatoryRouteStops, difficultyFilter: $routeDifficultyFilter,
                    routeRequestID: $routeRequestID, usesCurrentLocation: usesCurrentRouteStart,
                    customOrigin: routeStartCoordinate, customOriginName: routeStartTitle,
                    planningControls: AnyView(planningControls), chosenStops: pinnedStops,
                    onNavigate: { navigationWalk = $0 }, onClose: { showRoutePlanner = false })
                    .presentationDetents([.fraction(0.5), .large])
                    .presentationContentInteraction(.scrolls)
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(PausePathPalette.background)
            }
            .fullScreenCover(item: $navigationWalk) { WalkingNavigationView(walk: $0) }
        }
    }

    private var planningControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Start", systemImage: "location.fill").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Button { setRouteStartToCurrentLocation() } label: { Label("Current location", systemImage: "location.fill") }
                    Button { setRouteStartToCustomPlace() } label: { Label("Set my own", systemImage: "magnifyingglass") }
                } label: {
                    Label(routeStartTitle, systemImage: "chevron.down")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                }.accessibilityLabel("Starting location: \(routeStartTitle). Choose Current location or Set my own.")
            }

            if !usesCurrentRouteStart {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search starting address or place", text: $routeStartQuery)
                        .submitLabel(.search)
                        .onSubmit { Task { await searchRouteStarts(routeStartQuery) } }
                        .onChange(of: routeStartQuery) { _, value in
                            if routeStart?.name != value { routeStart = nil }
                            routeStartSearchMessage = ""
                            routeStartSearchTask?.cancel()
                            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { routeStartMatches = []; return }
                            routeStartSearchTask = Task {
                                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                                await searchRouteStarts(value)
                            }
                        }
                    if routeStartSearchInProgress { ProgressView().controlSize(.small) }
                    if !routeStartQuery.isEmpty {
                        Button { routeStartQuery = ""; routeStart = nil; routeStartMatches = [] } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.accessibilityLabel("Clear starting location")
                    }
                }.padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                if !routeStartMatches.isEmpty && routeStart == nil {
                    destinationSuggestions(routeStartMatches, selecting: selectRouteStart)
                } else if !routeStartSearchMessage.isEmpty {
                    Text(routeStartSearchMessage).font(.caption).foregroundStyle(.secondary)
                } else if routeStart != nil {
                    Label("Start: \(routeStartTitle)", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            } else {
                if isFresh(discovery.currentLocation) {
                    Label("Using this device’s location", systemImage: "location.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else if discovery.authorizationStatus == .denied || discovery.authorizationStatus == .restricted {
                    Button("Allow location in Settings", systemImage: "location.slash") {
                        requestLocationAccess()
                    }.font(.caption.weight(.semibold))
                } else {
                    Button("Get current location", systemImage: "location.circle") {
                        requestLocationAccess()
                    }.font(.caption.weight(.semibold))
                }
                if currentLocationRequested && !isFresh(discovery.currentLocation) {
                    Text(discovery.status).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Search a destination", text: $routeDestinationQuery)
                    .focused($searchFocused).submitLabel(.search)
                    .onSubmit { Task { await searchRouteDestinations(routeDestinationQuery) } }
                    .onChange(of: routeDestinationQuery) { _, value in
                        if routeDestination?.name != value {
                            routeDestination = nil
                            routeDestinationMatches = []
                            routeSearchMessage = ""
                            discovery.routeOptions = []
                            discovery.selectedRouteOptionID = nil
                        }
                        routeSearchTask?.cancel()
                        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        routeSearchTask = Task {
                            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                            await searchRouteDestinations(value)
                        }
                    }
                if !routeDestinationQuery.isEmpty {
                    Button { routeDestinationQuery = ""; routeDestinationMatches = []; routeDestination = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.accessibilityLabel("Clear destination search")
                }

            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))

            HStack(spacing: 8) {
                Menu {
                    ForEach(RoutePlannerDifficultyFilter.allCases) { filter in
                        Button { routeDifficultyFilter = filter } label: {
                            if filter == routeDifficultyFilter { Label(filter.rawValue, systemImage: "checkmark") } else { Text(filter.rawValue) }
                        }
                    }
                } label: { topFilterPill("Difficulty: \(routeDifficultyFilter.rawValue)", icon: "figure.walk") }
                Menu {
                    ForEach(FacilityKind.allCases, id: \.self) { kind in
                        Toggle(kind.chipTitle, isOn: Binding(get: { mandatoryRouteStops.contains(kind) }, set: { selected in
                            if selected { mandatoryRouteStops.insert(kind) } else { mandatoryRouteStops.remove(kind) }
                            clearRoutePreview()
                        }))
                    }
                } label: {
                    topFilterPill(mandatoryRouteStops.isEmpty ? "Must include: Any" : "Must include: \(mandatoryRouteStops.map(\.chipTitle).sorted().joined(separator: ", "))", icon: "mappin.and.ellipse")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            if !routeDestinationMatches.isEmpty && routeDestination == nil {
                destinationSuggestions(routeDestinationMatches, selecting: selectRouteDestination)
            } else if routeSearchInProgress {
                ProgressView("Finding nearby destinations…").font(.caption).padding(.vertical, 3)
            } else if !routeSearchMessage.isEmpty {
                Text(routeSearchMessage).font(.caption).foregroundStyle(.secondary)
            } else if let routeDestination {
                Label("End: \(routeDestination.name ?? routeDestinationQuery)", systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 8)
            }

            if !usesCurrentRouteStart && routeStart == nil {
                Text("Choose a starting place before searching nearby destinations.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func destinationSuggestions(_ matches: [MKMapItem], selecting: @escaping (MKMapItem) -> Void) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(matches.prefix(20).enumerated()), id: \.offset) { index, item in
                    Button { selecting(item) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name ?? "Place").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(address(of: item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let location = routeStartLocation {
                                Text(distanceText(from: location.coordinate, to: item.placemark.coordinate))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 4)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(item.name ?? "Place"), \(address(of: item))")
                        .accessibilityHint("Select this location")
                    if index < min(matches.count, 20) - 1 { Divider() }
                }
            }
        }
        .frame(height: min(CGFloat(min(matches.count, 20)) * 66, 198))
        .scrollIndicators(.visible)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func topFilterPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    }

    private func requestLocationAccess() {
        currentLocationRequested = true
        if discovery.authorizationStatus == .denied || discovery.authorizationStatus == .restricted,
           let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            openURL(settingsURL)
        } else {
            discovery.useLocation()
        }
    }

    private func setRouteStartToCurrentLocation() {
        usesCurrentRouteStart = true
        currentLocationRequested = true
        routeStart = nil
        routeStartQuery = ""
        routeStartMatches = []
        discovery.useLocation()
        clearRoutePreview()
        if !routeDestinationQuery.isEmpty { Task { await searchRouteDestinations(routeDestinationQuery) } }
    }

    private func setRouteStartToCustomPlace() {
        usesCurrentRouteStart = false
        routeStart = nil
        routeStartQuery = ""
        routeStartMatches = []
        routeDestinationMatches = []
        clearRoutePreview()
    }

    private func searchRouteStarts(_ query: String) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            routeStartMatches = []
            return
        }
        routeStartSearchInProgress = true
        defer { routeStartSearchInProgress = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleaned
        request.resultTypes = [.pointOfInterest, .address]
        let currentLocation = isFresh(discovery.currentLocation) ? discovery.currentLocation : nil
        if let currentLocation {
            request.region = MKCoordinateRegion(center: currentLocation.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        } else if camera.positionedByUser, let visibleRegion {
            request.region = visibleRegion
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard routeStartQuery.trimmingCharacters(in: .whitespacesAndNewlines) == cleaned else { return }
            routeStartMatches = response.mapItems.sorted { left, right in
                guard let currentLocation else { return (left.name ?? "") < (right.name ?? "") }
                return CLLocation(latitude: left.placemark.coordinate.latitude, longitude: left.placemark.coordinate.longitude).distance(from: currentLocation) <
                    CLLocation(latitude: right.placemark.coordinate.latitude, longitude: right.placemark.coordinate.longitude).distance(from: currentLocation)
            }
            routeStartSearchMessage = routeStartMatches.isEmpty ? "No starting places found. Try a full address or nearby landmark." : ""
        } catch {
            guard routeStartQuery.trimmingCharacters(in: .whitespacesAndNewlines) == cleaned else { return }
            routeStartMatches = []
            routeStartSearchMessage = "Starting place search is unavailable. Check your connection and try again."
        }
    }

    private func selectRouteStart(_ item: MKMapItem) {
        routeStart = item
        routeStartQuery = item.name ?? address(of: item)
        routeStartMatches = []
        clearRoutePreview()
        moveMapToRouteStart()
        if !routeDestinationQuery.isEmpty { Task { await searchRouteDestinations(routeDestinationQuery) } }
    }

    private func moveMapToRouteStart() {
        guard let coordinate = routeStartCoordinate else { return }
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_400, longitudinalMeters: 1_400)
        visibleRegion = region
        camera = .region(region)
        searched = true
        Task { await loadArea(region) }
    }

    private func clearRoutePreview() {
        discovery.route = nil
        discovery.itinerary = []
        discovery.routeOptions = []
        discovery.selectedRouteOptionID = nil
        if showRoutePlanner && routeDestination != nil { routeRequestID = UUID() }
    }

    private func searchRouteDestinations(_ query: String) async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let location = routeStartLocation else {
            routeDestinationMatches = []
            if !cleaned.isEmpty && usesCurrentRouteStart { discovery.useLocation() }
            return
        }
        routeSearchInProgress = true
        defer { routeSearchInProgress = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = cleaned
        request.resultTypes = [.pointOfInterest, .address]
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 30_000, longitudinalMeters: 30_000)
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard routeDestinationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == cleaned else { return }
            routeDestinationMatches = response.mapItems.sorted {
                CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude).distance(from: location) <
                    CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude).distance(from: location)
            }
            routeSearchMessage = routeDestinationMatches.isEmpty ? "No nearby matches. Try a more specific destination." : ""
        } catch {
            guard routeDestinationQuery.trimmingCharacters(in: .whitespacesAndNewlines) == cleaned else { return }
            routeDestinationMatches = []
            routeSearchMessage = "Destination search is unavailable. Check your connection and try again."
        }
    }

    private func selectRouteDestination(_ item: MKMapItem) {
        routeDestination = item
        routeDestinationQuery = item.name ?? address(of: item)
        routeDestinationMatches = []
        clearRoutePreview()
        searchFocused = false
    }

    private func address(of item: MKMapItem) -> String {
        let place = item.placemark
        return [place.subThoroughfare, place.thoroughfare, place.locality, place.administrativeArea]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func distanceText(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> String {
        let meters = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        return distanceUnit.nearby(meters) + " away"
    }

    private var topControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(PausePathPalette.teal)
                TextField("Search places or areas", text: $browseQuery)
                    .focused($searchFocused).submitLabel(.search)
                    .onSubmit { searchBrowse() }
                    .onChange(of: browseQuery) { _, _ in if searchFocused { searchBrowse() } }
                if browseLoading { ProgressView().controlSize(.small) }
                if !browseQuery.isEmpty {
                    Button { browseQuery = ""; browseMatches = []; browseMessage = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.frame(minWidth: 44, minHeight: 44).accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 15).frame(minHeight: 52)
                .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.12), radius: 9, y: 3)
            HStack(spacing: 2) {
                ForEach(FacilityKind.allCases, id: \.self) { kind in
                    Button {
                        if kinds.contains(kind) { kinds.remove(kind) } else { kinds.insert(kind) }
                        if let selectedID, let place = discovery.places.first(where: { $0.id == selectedID }), !kinds.contains(place.kind) { self.selectedID = nil }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(kinds.contains(kind) ? kind.mapColor : Color.secondary.opacity(0.55), in: Circle())
                            Text(filterTitle(kind))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(kinds.contains(kind) ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(kinds.contains(kind) ? kind.mapColor.opacity(0.13) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(filterTitle(kind))
                    .accessibilityValue(kinds.contains(kind) ? "Shown" : "Hidden")
                    .accessibilityAddTraits(kinds.contains(kind) ? [.isSelected] : [])
                }
            }
            .padding(4)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 17))
            .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
            if !browseMatches.isEmpty {
                destinationSuggestions(browseMatches, selecting: selectBrowseResult)
            } else if !browseMessage.isEmpty {
                Text(browseMessage).font(.caption).padding(8).background(.regularMaterial, in: Capsule())
            }
        }.padding(.horizontal, 16).padding(.top, 8)
    }

    private func filterTitle(_ kind: FacilityKind) -> String {
        switch kind { case .bench: "Benches"; case .bathroom: "Bathrooms"; case .fountain: "Water"; case .cafe: "Cafés" }
    }

    private func searchBrowse() {
        browseTask?.cancel()
        let query = browseQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        browseMatches = []; browseMessage = ""; browseLoading = !query.isEmpty
        guard !query.isEmpty else { return }
        browseTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(350))
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = [.pointOfInterest, .address]
                if let visibleRegion { request.region = visibleRegion }
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled, browseQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
                browseMatches = response.mapItems
                browseMessage = browseMatches.isEmpty ? "No matching places. Try a city or full address." : ""
                browseLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                browseLoading = false
                browseMessage = "Search is unavailable. You can still explore the map."
            }
        }
    }

    private func selectBrowseResult(_ item: MKMapItem) {
        browseTask?.cancel(); browseLoading = false; browseMatches = []; searchFocused = false
        browseQuery = item.name ?? "Selected place"
        routeDestination = item; routeDestinationQuery = item.name ?? "Selected place"
        clearRoutePreview(); selectedID = nil; didPositionMap = true
        let region = MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
        visibleRegion = region; camera = .region(region)
        Task { await loadArea(region) }
    }

    private var areaIsUpdating: Bool { discovery.isLoading || discovery.areaLoadState == "loading" }

    private var areaMessage: String {
        if discovery.showingSavedArea, let date = discovery.savedAreaDate {
            return "Saved " + date.formatted(date: .abbreviated, time: .shortened) + " · availability may have changed"
        }
        if areaIsUpdating { return "Updating this area…" }
        if kinds.isEmpty { return "Choose a category to show stops" }
        if visiblePlaces.isEmpty {
            if !searched { return "Search an area or use your location" }
            return discovery.areaLoadState == "ready" ? "No mapped stops for these filters" : "Stops could not finish loading. Try refreshing."
        }
        return "\(visiblePlaces.count) mapped stops" + (discovery.areaLoadState == "ready" ? "" : " · More may be available")
    }

    private var compactAreaMessage: String {
        if areaIsUpdating { return "Updating area…" }
        if discovery.showingSavedArea { return "Saved area" }
        if kinds.isEmpty { return "Choose filters" }
        if !visiblePlaces.isEmpty { return "\(visiblePlaces.count) mapped stops" }
        if !searched { return "Search an area" }
        return discovery.areaLoadState == "ready" ? "No mapped stops" : "Stops unavailable"
    }

    private var areaStatusOverlay: some View {
        Menu {
            Button("Refresh this area", systemImage: "arrow.clockwise") { Task { await refresh() } }
                .disabled(discovery.isLoading)
            if discovery.showingSavedArea { Text("Saved stop details may have changed") }
        } label: {
            HStack(spacing: 6) {
                if areaIsUpdating { ProgressView().controlSize(.mini) }
                Text(compactAreaMessage).lineLimit(1)
                Image(systemName: "arrow.clockwise").font(.caption2.weight(.semibold))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(PausePathPalette.teal)
            .padding(.horizontal, 10)
            .frame(minHeight: 36)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(PausePathPalette.teal.opacity(0.1)))
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityLabel("Map status: \(areaMessage)")
        .accessibilityHint("Open options to refresh this area")
    }

    private var mapQuickActions: some View {
        HStack(spacing: 8) {
            mapQuickAction("location.fill", label: "Center map on my location") {
                searchFocused = false; requestLocationAccess()
            }
            mapQuickAction("exclamationmark", label: "Suggest a stop at map center") {
                reportPlace = nil; showReport = true
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func mapQuickAction(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PausePathPalette.teal)
        .background(PausePathPalette.surface, in: Circle())
        .shadow(color: .black.opacity(0.15), radius: 7, y: 3)
        .accessibilityLabel(label)
    }

    private func bottomControls(availableHeight: CGFloat) -> some View {
        let heights: [CGFloat] = [compactSheetHeight, max(compactSheetHeight, availableHeight * 0.43), max(compactSheetHeight, availableHeight * 0.73)]
        let height = min(max(heights[sheetLevel] - sheetDrag, compactSheetHeight), availableHeight * 0.78)
        return VStack(spacing: 0) {
            VStack(spacing: 0) {
                sheetHeader
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 12)
                        .updating($sheetDrag) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            let projected = heights[sheetLevel] - value.predictedEndTranslation.height
                            animate { sheetLevel = heights.indices.min(by: { abs(heights[$0]-projected) < abs(heights[$1]-projected) }) ?? sheetLevel }
                        })
                if sheetLevel > 0 || sheetDrag < -20 {
                    Divider().padding(.horizontal, 16)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if sheetLevel == 2, let place = selectedPlace { selectedCard(place) }
                            else {
                                if !pinnedStops.isEmpty {
                                    Text("\(pinnedStops.count) stops added to your route").font(.subheadline.weight(.semibold))
                                    ForEach(pinnedStops) { stop in
                                        HStack { Text(stop.item.name ?? stop.kind.rawValue).font(.caption); Spacer(); Button("Remove") { pinnedStops.removeAll { $0.id == stop.id }; clearRoutePreview() } }
                                    }
                                }
                                if visiblePlaces.isEmpty {
                                    ContentUnavailableView(areaIsUpdating ? "Finding stops" : areaMessage, systemImage: areaIsUpdating ? "map" : "mappin.slash", description: Text(areaIsUpdating ? "Saved stops will appear as data arrives." : "Try another category or move the map."))
                                }
                                ForEach(visiblePlaces) { place in
                                    Button { select(place) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: place.kind.symbol).foregroundStyle(.white).frame(width: 42, height: 42).background(place.kind.mapColor, in: Circle())
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(place.item.name ?? place.kind.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(PausePathPalette.teal)
                                                Text(distanceLabel(place)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                        }.padding(.vertical, 6).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }.padding(16)
                    }.scrollDismissesKeyboard(.interactively)
                }
                Spacer(minLength: 0)
            }
            .frame(height: searchFocused ? compactSheetHeight : height)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(PausePathPalette.teal.opacity(0.12)))
            .shadow(color: .black.opacity(0.12), radius: 16, y: 4)
        }.padding(.horizontal, 12).padding(.bottom, 8)
    }

    private var sheetHeader: some View {
        VStack(spacing: 3) {
            Capsule().fill(PausePathPalette.teal.opacity(0.25)).frame(width: 32, height: 4).padding(.top, 8)
            HStack(spacing: 10) {
                if sheetLevel == 0, let place = selectedPlace {
                    Button { animate { sheetLevel = 2 } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: place.kind.symbol)
                                .font(.caption.weight(.bold)).foregroundStyle(.white)
                                .frame(width: 36, height: 36).background(place.kind.mapColor, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.item.name ?? place.kind.chipTitle)
                                    .font(.subheadline.weight(.bold)).foregroundStyle(.primary).lineLimit(1)
                                Text("View stop details").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up")
                                .font(.caption.weight(.bold)).foregroundStyle(PausePathPalette.teal)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.plain).accessibilityHint("Open stop details")
                } else if sheetLevel == 0 {
                    Button { openPlanner() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "figure.walk")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(PausePathPalette.ink)
                                .frame(width: 36, height: 36)
                                .background(PausePathPalette.lime, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Plan a walk").font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                                Text("Choose a route with places to pause")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Button { animate { sheetLevel = 1 } } label: {
                        Image(systemName: "list.bullet")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }.buttonStyle(.plain).foregroundStyle(PausePathPalette.teal)
                        .accessibilityLabel("Show nearby stops")
                } else {
                    Button { animate { sheetLevel = sheetLevel == 1 ? 2 : 1 } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sheetLevel == 2 && selectedPlace != nil ? "Stop details" : "Nearby stops")
                                .font(.subheadline.weight(.bold)).foregroundStyle(PausePathPalette.teal)
                            if sheetLevel != 2 || selectedPlace == nil {
                                Text("\(visiblePlaces.count) mapped in this area")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).accessibilityHint("Change panel size")
                    if sheetLevel != 2 || selectedPlace == nil {
                        Button { openPlanner() } label: {
                            Label("Plan", systemImage: "figure.walk").font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }.buttonStyle(.plain).foregroundStyle(PausePathPalette.teal)
                    }
                }
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }
        .accessibilityAdjustableAction { direction in
            animate { sheetLevel = min(2, max(0, sheetLevel + (direction == .increment ? 1 : -1))) }
        }
    }

    private func openPlanner() {
        searchFocused = false
        if let place = selectedPlace { routeDestination = place.item; routeDestinationQuery = place.item.name ?? "Selected stop" }
        routeRequestID = UUID(); showRoutePlanner = true
    }

    private func distanceLabel(_ place: DiscoveredPlace) -> String {
        guard let location = discovery.currentLocation, isFresh(location) else { return "Distance from you unknown" }
        return distanceText(from: location.coordinate, to: place.item.placemark.coordinate) + " · straight-line"
    }

    private func selectedCard(_ place: DiscoveredPlace) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: place.kind.symbol)
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 42, height: 42).background(place.kind.mapColor, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(place.item.name ?? place.kind.chipTitle).font(.title3.bold()).foregroundStyle(PausePathPalette.teal)
                    Text(place.kind.chipTitle + " · " + distanceLabel(place))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { animate { selectedID = nil } } label: { Image(systemName: "xmark").frame(width: 44, height: 44).background(.quaternary, in: Circle()) }.accessibilityLabel("Close stop details")
            }
            VStack(alignment: .leading, spacing: 9) {
                Label(place.shared?.hoursDescription ?? "Hours unknown", systemImage: "clock")
                Label("Access: \(place.shared?.attributes?.access ?? "Unknown")", systemImage: "door.left.hand.open")
                Label("Verified: \(place.shared?.verificationDescription ?? "Unknown")", systemImage: "checkmark.shield")
            }
            .font(.subheadline)
            .foregroundStyle(PausePathPalette.teal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(PausePathPalette.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
            DisclosureGroup("Accessibility & more") {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Wheelchair access: \(place.shared?.accessibilityDescription ?? "Unknown")", systemImage: "figure.roll")
                    Label("Backrest: \(place.shared?.backrestDescription ?? "Unknown") · Shade: \(place.shared?.shadeDescription ?? "Unknown")", systemImage: "sun.max")
                    if let summary = place.businessSummary { Text(summary) }
                    if let website = place.website { Link("Business website", destination: website) }
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            }
            .font(.subheadline.weight(.semibold))
            Button { routeDestination = place.item; routeDestinationQuery = place.item.name ?? "Selected stop"; openPlanner() } label: {
                Label("Navigate here", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.plain).font(.headline).foregroundStyle(PausePathPalette.ink)
                .background(PausePathPalette.lime, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHint("Review a walking route before starting navigation")
            HStack {
                Button {
                    if pinnedStops.contains(where: { $0.id == place.id }) { pinnedStops.removeAll { $0.id == place.id } }
                    else if pinnedStops.count < 3 { pinnedStops.append(place) }
                    clearRoutePreview()
                } label: { Label(pinnedStops.contains(where: { $0.id == place.id }) ? "Remove from route" : "Add to route", systemImage: "plus.circle") }
                    .disabled(pinnedStops.count >= 3 && !pinnedStops.contains(where: { $0.id == place.id }))
                Spacer()
                Button { reportPlace = place; showReport = true } label: { Label("Report", systemImage: "exclamationmark.bubble") }
            }.font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            if pinnedStops.count >= 3 { Text("Three stops added. Remove one to choose another.").font(.caption).foregroundStyle(.secondary) }
            Text("\(place.provider) · Hours and access may change.").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func animate(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25), action)
    }
    private func select(_ place: DiscoveredPlace) {
        searchFocused = false
        cancelAreaRefresh()
        discovery.cancelPending()
        animate { sheetLevel = 2; selectedID = place.id; discovery.route = nil; discovery.itinerary = []; discovery.routeOptions = []; discovery.selectedRouteOptionID = nil }
    }
    private func cancelAreaRefresh() {
        areaRefreshTask?.cancel()
        areaRefreshTask = nil
    }

    private func areaChanged(_ region: MKCoordinateRegion) -> Bool {
        guard let previous = lastRequestedRegion else { return true }
        // Ignore small camera/layout adjustments and GPS jitter.
        let latitudeShift = abs(region.center.latitude - previous.center.latitude)
        let rawLongitudeShift = abs(region.center.longitude - previous.center.longitude)
        let longitudeShift = min(rawLongitudeShift, 360 - rawLongitudeShift)
        return latitudeShift > previous.span.latitudeDelta * 0.1 ||
            longitudeShift > previous.span.longitudeDelta * 0.1 ||
            abs(region.span.latitudeDelta - previous.span.latitudeDelta) > previous.span.latitudeDelta * 0.15 ||
            abs(region.span.longitudeDelta - previous.span.longitudeDelta) > previous.span.longitudeDelta * 0.15
    }

    private func scheduleAreaRefresh(_ region: MKCoordinateRegion) {
        cancelAreaRefresh()
        guard areaChanged(region) else { return }
        areaRefreshTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await loadArea(region)
        }
    }

    private func moveToDiscoveredArea() {
        // GPS updates never move a map the user is browsing.
        guard !didPositionMap else { return }
        camera = .region(discovery.region)
        if selectedID == nil { scheduleAreaRefresh(discovery.region) }
    }

    private func loadArea(_ region: MKCoordinateRegion) async {
        guard !Task.isCancelled else { return }
        searched = true
        lastRequestedRegion = nil
        // Only remember a successfully completed area. A cancelled request
        // must not suppress the next refresh for the same viewport.
        if await discovery.discover(kinds: Set(FacilityKind.allCases), region: region) {
            lastRequestedRegion = region
        }
    }

    private func refresh() async {
        cancelAreaRefresh()
        await loadArea(visibleRegion ?? discovery.region)
    }
    private func fitRouteInMap() {
        let rect = discovery.itinerary.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
        if !rect.isNull { camera = .rect(rect) }
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
