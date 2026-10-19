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
    let preferences: RoutePreferences
    let profile: PausePathProfile
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
    @State private var selectedStopIDs: [UUID] = []
    @State private var showRoutePlanner = false
    @State private var showResults = false
    @State private var cardCollapsed = false
    @State private var navigationWalk: GeneratedWalk?
    @State private var searched = false
    @State private var showReport = false
    @State private var reportPlace: DiscoveredPlace?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var areaRefreshTask: Task<Void, Never>?
    @State private var lastRequestedRegion: MKCoordinateRegion?
    @State private var isPreviewingRoute = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visiblePlaces: [DiscoveredPlace] { discovery.places.filter { kinds.contains($0.kind) } }
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
                if let start = routeStartCoordinate {
                    Annotation("Selected route start", coordinate: start, anchor: .bottom) {
                        Image(systemName: "location.fill")
                            .font(.headline).foregroundStyle(.white).frame(width: 42, height: 42)
                            .background(Color(red: 0.02, green: 0.42, blue: 0.34), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 3)).shadow(radius: 4)
                            .accessibilityLabel("Selected route starting point")
                    }.annotationTitles(.hidden)
                }
                ForEach(visiblePlaces) { place in
                    Annotation(place.item.name ?? place.kind.rawValue, coordinate: place.item.placemark.coordinate, anchor: .bottom) {
                        Button { select(place) } label: {
                            VStack(spacing: -3) {
                                Image(systemName: place.kind.symbol)
                                    .font(.system(size: selectedID == place.id ? 20 : 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: selectedID == place.id ? 48 : 38, height: selectedID == place.id ? 48 : 38)
                                    .background(place.kind.mapColor, in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 3))
                                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 12)).foregroundStyle(place.kind.mapColor)
                            }.shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                                .frame(minWidth: 44, minHeight: 52)
                        }.buttonStyle(.plain)
                            .disabled(showRoutePlanner)
                            .accessibilityLabel("\(place.item.name ?? "Possible stop"), \(place.kind.rawValue)")
                            .accessibilityHint("Show stop details and walking directions")
                            .accessibilityAddTraits(selectedID == place.id ? [.isSelected] : [])
                    }.annotationTitles(.hidden)
                }
                if discovery.route != nil {
                    ForEach(Array(discovery.itinerary.enumerated()), id: \.offset) { index, leg in
                        MapPolyline(leg.polyline).stroke(index == 0 ? .teal : .blue, lineWidth: 6)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleRegion = context.region
                // Programmatic camera changes (such as fitting a route) must not
                // replace the selected stop or erase its directions.
                guard camera.positionedByUser, !isPreviewingRoute,
                      discovery.route == nil, !showReport, !showResults, !showRoutePlanner, navigationWalk == nil else { return }
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
                if !showRoutePlanner { bottomControls }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showRoutePlanner)
            .toolbarBackground(.hidden, for: .tabBar)
            .task {
                camera = .automatic
            }
            .task {
                discovery.places = []; selectedID = nil; discovery.route = nil
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard scenePhase == .active, !discovery.isLoading,
                          discovery.route == nil, selectedID == nil, !showReport, !showResults, !showRoutePlanner, navigationWalk == nil else { continue }
                    guard let location = discovery.currentLocation, isFresh(location) else { continue }
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
                guard usesCurrentRouteStart, let location = discovery.currentLocation, isFresh(location) else { return }
                let region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 1_400, longitudinalMeters: 1_400)
                visibleRegion = region
                camera = .region(region)
                clearRoutePreview()
                Task { await loadArea(region) }
                if !routeDestinationQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Task { await searchRouteDestinations(routeDestinationQuery) }
                }
            }
            .onDisappear {
                cancelAreaRefresh()
                routeStartSearchTask?.cancel()
                routeSearchTask?.cancel()
                discovery.cancelPending()
            }
            .onChange(of: showResults) { if showResults { cancelAreaRefresh() } }
            .onChange(of: showRoutePlanner) { if showRoutePlanner { cancelAreaRefresh() } }
            .onChange(of: navigationWalk?.id) { if navigationWalk != nil { cancelAreaRefresh() } }
            .onChange(of: discovery.selectedRouteOptionID) { fitRouteInMap() }
            .sheet(isPresented: $showResults) { resultsSheet }
            .sheet(isPresented: $showRoutePlanner) {
                ExploreRoutePlannerView(discovery: discovery, preferences: preferences, profile: profile, initialDestination: selectedPlace,
                    destinationQuery: $routeDestinationQuery, destination: $routeDestination,
                    mandatoryKinds: $mandatoryRouteStops, difficultyFilter: $routeDifficultyFilter,
                    routeRequestID: $routeRequestID, usesCurrentLocation: usesCurrentRouteStart,
                    customOrigin: routeStartCoordinate, customOriginName: routeStartTitle,
                    onNavigate: { navigationWalk = $0 }, onClose: { showRoutePlanner = false })
                    .presentationDetents([.fraction(0.5)])
                    .presentationContentInteraction(.scrolls)
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Color(.systemGroupedBackground))
            }
            .fullScreenCover(item: $navigationWalk) { WalkingNavigationView(walk: $0) }
        }
    }

    private var topControls: some View {
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
                Menu {
                    ForEach(FacilityKind.allCases, id: \.self) { kind in
                        Toggle(kind.chipTitle, isOn: Binding(get: { kinds.contains(kind) }, set: { selected in
                            if selected { kinds.insert(kind) } else { kinds.remove(kind) }
                            if let selectedID, let selectedKind = discovery.places.first(where: { $0.id == selectedID })?.kind,
                               !kinds.contains(selectedKind) { self.selectedID = nil; discovery.route = nil }
                        }))
                    }
                } label: { Image(systemName: "checklist").font(.title3).frame(width: 40, height: 40) }
                    .accessibilityLabel("Choose which stop categories appear on the map")
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
        return meters < 1000 ? String(format: "%.0f m away", meters) : String(format: "%.1f km away", meters / 1000)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                Spacer()
                Button { Task { await refresh() } } label: {
                    HStack(spacing: 8) {
                        if discovery.isLoading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text(discovery.isLoading ? "Searching…" : "Refresh this area").font(.subheadline.weight(.semibold))
                    }.padding(.horizontal, 18).frame(minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }.disabled(discovery.isLoading)
                Spacer()
                Button {
                    searchFocused = false; cancelAreaRefresh(); discovery.cancelPending(); selectedID = nil; discovery.route = nil; requestLocationAccess()
                } label: {
                    Image(systemName: "location.fill").font(.title3).frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle()).shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }.accessibilityLabel("Center map on my location")
                Button {
                    cancelAreaRefresh(); discovery.cancelPending()
                    reportPlace = nil; showReport = true
                } label: {
                    Image(systemName: "exclamationmark")
                        .font(.title3.weight(.semibold)).frame(width: 48, height: 48)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                }.accessibilityLabel("Suggest a stop at map center")
                    .accessibilityHint("Report a missing bench, bathroom, fountain or café")
            }
            if !searchFocused {
                VStack(alignment: .leading, spacing: 6) {
                    Button { animate { cardCollapsed.toggle() } } label: {
                        Image(systemName: cardCollapsed ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel(cardCollapsed ? "Show stop card" : "Hide stop card")
                    if !cardCollapsed {
                    if let place = selectedPlace { selectedCard(place) }
                    else if let option = discovery.routeOptions.first(where: { $0.id == discovery.selectedRouteOptionID }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(option.title) to \(option.destinationName)").font(.headline)
                            Text("\(option.distance / 1000, specifier: "%.1f") km • about \(Int(option.duration / 60)) min")
                                .font(.subheadline).foregroundStyle(.secondary)
                            RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: option.distance, durationSeconds: option.duration))
                            Button("Navigate this route", systemImage: "figure.walk") {
                                navigationWalk = GeneratedWalk(name: "Walk to \(option.destinationName)", legs: option.legs, preferences: preferences)
                            }.buttonStyle(.bordered)
                        }
                    }
                    else {
                        HStack(spacing: 10) {
                            Text(kinds.isEmpty ? "Choose a stop filter" : "\(visiblePlaces.count) stops nearby")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Button { showResults = true } label: {
                                Image(systemName: "list.bullet").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                            }.accessibilityLabel("Show stops as a list")
                        }
                    }
                }
                }.padding(.horizontal, 12).padding(.bottom, cardCollapsed ? 0 : 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { value in
                        guard abs(value.translation.height) > abs(value.translation.width) else { return }
                        if value.translation.height > 25 { animate { cardCollapsed = true } }
                        else if value.translation.height < -25 { animate { cardCollapsed = false } }
                    })
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Button {
                searchFocused = false
                routeStartSearchTask?.cancel()
                routeSearchTask?.cancel()
                routeRequestID = UUID()
                showRoutePlanner = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    Text(discovery.isLoading ? "Finding routes…" : "Search routes")
                    Spacer()
                    Image(systemName: "chevron.up")
                }
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 54)
                .padding(.horizontal, 18)
            }
            .buttonStyle(.borderedProminent)
            .disabled(((routeDestination == nil && selectedPlace == nil) || routeStartCoordinate == nil) || discovery.isLoading)
            .accessibilityHint("Expand route choices from the selected starting point")
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                guard value.translation.height < -40, routeStartCoordinate != nil,
                      routeDestination != nil || selectedPlace != nil else { return }
                searchFocused = false
                routeRequestID = UUID()
                showRoutePlanner = true
            })
        }.padding(.horizontal, 16).padding(.bottom, 12)
    }

    private func selectedCard(_ place: DiscoveredPlace) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Label(place.item.name ?? "Possible stop", systemImage: place.kind.symbol)
                    .font(.headline).foregroundStyle(place.kind.mapColor).lineLimit(2)
                Spacer()
                Button { discovery.cancelPending(); animate { selectedID = nil; discovery.route = nil } } label: {
                    Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 44, height: 44).background(.quaternary, in: Circle())
                }.accessibilityLabel("Close stop details")
            }
            Text("\(place.provider) • \(place.kind.rawValue) • Seating and hours unverified")
                .font(.caption).foregroundStyle(.secondary)
            if let summary = place.businessSummary { Text(summary).font(.caption) }
            if let website = place.website { Link("Business website", destination: website) }
            if let poi = place.shared {
                HStack {
                    Text("Community confidence: \(Int(poi.confidence_score * 100))%").font(.caption)
                    Button("Report status") { reportPlace = place; showReport = true }
                }
            }
            if let route = discovery.route {
                let legs = discovery.itinerary.isEmpty ? [route] : discovery.itinerary
                let distance = legs.reduce(0) { $0 + $1.distance }
                let duration = legs.reduce(0) { $0 + $1.expectedTravelTime }
                let activeStops = discovery.routeOptions.first { $0.id == discovery.selectedRouteOptionID }?.stops
                HStack {
                    Text("\(distance / 1000, specifier: "%.1f") km • about \(Int(duration / 60)) min").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Navigate", systemImage: "figure.walk") {
                        navigationWalk = GeneratedWalk(name: "Walk to \(place.item.name ?? "destination")", legs: legs, preferences: preferences)
                    }.buttonStyle(.borderedProminent)
                }
                RouteDifficultyPreview(input: RouteDifficultyInput(distanceMeters: distance, durationSeconds: duration))
                Text("Start: your current location • End: \(place.item.name ?? "selected destination")")
                    .font(.caption2).foregroundStyle(.secondary)
                if let activeStops, !activeStops.isEmpty {
                    let names = activeStops.compactMap { $0.item.name }
                    Text("Stops: \(names.joined(separator: " → "))").font(.caption).foregroundStyle(.secondary)
                }
                if discovery.routeOptions.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Choose a route").font(.subheadline.weight(.semibold))
                        ForEach(discovery.routeOptions) { option in
                            Button { discovery.selectRouteOption(option.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: option.id == discovery.selectedRouteOptionID ? "largecircle.fill.circle" : "circle")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title).font(.subheadline.weight(.semibold))
                                        Text("\(option.distance / 1000, specifier: "%.1f") km • about \(Int(option.duration / 60)) min")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).frame(minHeight: 44)
                        }
                    }
                }
                Button("Change stops") {
                    discovery.route = nil; discovery.itinerary = []; discovery.routeOptions = []; discovery.selectedRouteOptionID = nil
                }
                    .font(.subheadline).buttonStyle(.plain)
            } else {
                Text("End destination: \(place.item.name ?? "selected place")")
                    .font(.subheadline.weight(.semibold))
                if !selectedStopIDs.isEmpty {
                    Text("Stops are visited in the order you select them.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(visiblePlaces.filter { $0.id != place.id }) { stop in
                    Button {
                        if let index = selectedStopIDs.firstIndex(of: stop.id) {
                            selectedStopIDs.remove(at: index)
                        } else if selectedStopIDs.count < 3 {
                            selectedStopIDs.append(stop.id)
                        } else {
                            discovery.status = "Choose up to three optional stops for one route."
                        }
                    } label: {
                        Label("\(selectedStopIDs.contains(stop.id) ? "Remove" : "Add") stop: \(stop.item.name ?? stop.kind.rawValue)",
                              systemImage: selectedStopIDs.contains(stop.id) ? "checkmark.circle.fill" : stop.kind.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(minHeight: 40)
                }
                if discovery.currentLocation == nil || !isFresh(discovery.currentLocation) {
                    Button { discovery.useLocation() } label: {
                        Label("Use my current location", systemImage: "location.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.bordered)
                } else {
                    Button { buildRoute(to: place) } label: {
                    Label(discovery.isLoading ? "Building route…" : "Build route from my location", systemImage: "figure.walk")
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).disabled(discovery.isLoading)
                }
                if discovery.status.hasPrefix("Walking directions unavailable") || discovery.status.hasPrefix("No walking route") { Text(discovery.status).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private var resultsSheet: some View {
        NavigationStack {
            List {
                Section {
                    Text("Possible facilities from map search. Confirm seating, access and opening hours before relying on a stop.").font(.callout).foregroundStyle(.secondary)
                }
                if visiblePlaces.isEmpty { Text("No stops for the selected filters. Search a different area or enable another category.") }
                ForEach(visiblePlaces) { place in
                    Button {
                        showResults = false; select(place)
                        camera = .region(MKCoordinateRegion(center: place.item.placemark.coordinate, latitudinalMeters: 800, longitudinalMeters: 800))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: place.kind.symbol).foregroundStyle(.white).frame(width: 36, height: 36).background(place.kind.mapColor, in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.item.name ?? "Possible stop").font(.headline).foregroundStyle(.primary)
                                Text(place.kind.rawValue).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.navigationTitle("Nearby pauses").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showResults = false } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func animate(_ action: () -> Void) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25), action)
    }
    private func select(_ place: DiscoveredPlace) {
        searchFocused = false
        cancelAreaRefresh()
        discovery.cancelPending()
        animate { cardCollapsed = false; selectedID = place.id; selectedStopIDs = []; discovery.route = nil; discovery.itinerary = []; discovery.routeOptions = []; discovery.selectedRouteOptionID = nil }
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
        camera = .region(discovery.region)
        // Also refresh after the user recenters on their location.
        if selectedID == nil { scheduleAreaRefresh(discovery.region) }
    }

    private func loadArea(_ region: MKCoordinateRegion) async {
        guard !Task.isCancelled else { return }
        searchFocused = false; selectedID = nil; searched = true
        lastRequestedRegion = nil
        // Only remember a successfully completed area. A cancelled request
        // must not suppress the next refresh for the same viewport.
        if await discovery.discover(kinds: Set(FacilityKind.allCases), region: region) {
            lastRequestedRegion = region
        }
    }

    private func refresh() async {
        cancelAreaRefresh()
        guard let location = discovery.currentLocation, isFresh(location) else {
            discovery.status = "Waiting for your device location. Allow location access or search for an area."
            discovery.useLocation()
            return
        }
        await loadArea(visibleRegion ?? discovery.region)
    }
    private func buildRoute(to place: DiscoveredPlace) {
        cancelAreaRefresh()
        isPreviewingRoute = true
        guard let location = discovery.currentLocation, isFresh(location) else {
            discovery.status = "A fresh location is needed. Tap Use my current location and allow location access."
            isPreviewingRoute = false
            return
        }
        let origin = location.coordinate
        let stops = selectedStopIDs.compactMap { id in visiblePlaces.first { $0.id == id } }
        Task {
            defer { isPreviewingRoute = false }
            await discovery.walkingDirections(to: place, from: origin, via: stops)
            fitRouteInMap()
        }
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
