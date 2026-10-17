import SwiftUI
import MapKit
import CoreLocation

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
    @State private var discovery = PlaceDiscovery()
    @State private var camera: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var query = ""
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
    @State private var areaRefreshTask: Task<Void, Never>?
    @State private var lastRequestedRegion: MKCoordinateRegion?
    @State private var isPreviewingRoute = false
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var visiblePlaces: [DiscoveredPlace] { discovery.places.filter { kinds.contains($0.kind) } }
    private var selectedPlace: DiscoveredPlace? { visiblePlaces.first { $0.id == selectedID } }

    var body: some View {
        Map(position: $camera) {
            UserAnnotation()
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
        .safeAreaInset(edge: .top, spacing: 0) { topControls }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomControls }
        .toolbarBackground(.hidden, for: .tabBar)
        .task {
            camera = .region(discovery.region)
            // Account task performs the initial load.
        }
        .task {
            discovery.places = []; selectedID = nil; discovery.route = nil
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard scenePhase == .active, !discovery.isLoading,
                      discovery.route == nil, selectedID == nil, !showReport, !showResults, !showRoutePlanner, navigationWalk == nil else { continue }
                await loadArea(visibleRegion ?? discovery.region)
            }
        }
        .sheet(isPresented: $showReport) {
            StopReportView(place: reportPlace,
                coordinate: reportPlace?.item.placemark.coordinate ?? (visibleRegion ?? discovery.region).center) {
                Task { await refresh() }
            }
        }
        .sheet(isPresented: $showRoutePlanner) {
            ExploreRoutePlannerView(discovery: discovery, preferences: preferences, initialDestination: selectedPlace) { walk in
                navigationWalk = walk
            }
        }
        .onChange(of: [discovery.region.center.latitude, discovery.region.center.longitude]) { moveToDiscoveredArea() }
        .onDisappear { cancelAreaRefresh(); discovery.cancelPending() }
        .onChange(of: showResults) { if showResults { cancelAreaRefresh() } }
        .onChange(of: showRoutePlanner) { if showRoutePlanner { cancelAreaRefresh() } }
        .onChange(of: navigationWalk?.id) { if navigationWalk != nil { cancelAreaRefresh() } }
        .onChange(of: discovery.selectedRouteOptionID) { fitRouteInMap() }
        .sheet(isPresented: $showResults) { resultsSheet }
        .fullScreenCover(item: $navigationWalk) { WalkingNavigationView(walk: $0) }
    }

    private var topControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("Search an area, then choose a destination", text: $query)
                    .focused($searchFocused).submitLabel(.search).onSubmit(search)
                    .accessibilityLabel("Search an area, then choose an end destination")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("Clear search")
                }
                if searchFocused {
                    Button(action: search) { Image(systemName: "arrow.right.circle.fill").font(.title2) }
                        .accessibilityLabel("Find area").disabled(discovery.isLoading)
                }
            }.padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FacilityKind.allCases, id: \.self) { kind in
                        let enabled = kinds.contains(kind)
                        Button {
                            animate {
                                if enabled { kinds.remove(kind) } else { kinds.insert(kind) }
                                if selectedID != nil, !visiblePlaces.contains(where: { $0.id == selectedID }) { discovery.cancelPending(); selectedID = nil; discovery.route = nil }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: kind.symbol)
                                Text("\(kind.chipTitle) \(discovery.places.filter { $0.kind == kind }.count)")
                                if enabled { Image(systemName: "checkmark").font(.caption.bold()) }
                            }.font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .foregroundStyle(enabled ? .white : kind.mapColor)
                                .background {
                                    if enabled { Capsule().fill(kind.mapColor) }
                                    else { Capsule().fill(.regularMaterial) }
                                }
                                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(kind.rawValue)
                            .accessibilityValue(enabled ? "Selected" : "Not selected")
                    }
                }.padding(.horizontal, 16).padding(.bottom, 5)
            }
        }.padding(.top, 12).padding(.bottom, 8)
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
                    searchFocused = false; cancelAreaRefresh(); discovery.cancelPending(); selectedID = nil; discovery.route = nil; discovery.useLocation()
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
                    Button {
                        showRoutePlanner = true
                    } label: {
                        Label("Plan a route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent)
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
                        HStack(spacing: 12) {
                            Image(systemName: "figure.walk").font(.title2).foregroundStyle(.teal)
                                .frame(width: 44, height: 44).background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(kinds.isEmpty ? "Choose a filter" : "Find your next pause").font(.headline)
                                Text(kinds.isEmpty ? "Turn on a category to show its pins." : "\(visiblePlaces.count) possible stops • choose a destination or route stop")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { showResults = true } label: {
                                Image(systemName: "list.bullet").font(.title3).frame(width: 44, height: 44)
                            }.accessibilityLabel("Show stops as a list")
                        }
                        if !discovery.status.isEmpty {
                            Text(discovery.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
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
        await loadArea(visibleRegion ?? discovery.region)
    }
    private func search() {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelAreaRefresh()
        searchFocused = false; selectedID = nil
        Task {
            if await discovery.findArea(query) {
                // Use the same debounced path as location changes, not a competing load.
                lastRequestedRegion = nil
                moveToDiscoveredArea()
            }
        }
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
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 100 && Date().timeIntervalSince(location.timestamp) <= 60
    }
}
