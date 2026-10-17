import MapKit
import CoreLocation
import Observation

struct DiscoveredPlace: Identifiable {
    let id: UUID
    init(id: UUID = UUID(), item: MKMapItem, kind: FacilityKind, shared: SharedPOI? = nil, provider: String = "Apple Maps", businessID: String? = nil, businessSummary: String? = nil, website: URL? = nil) {
        self.id = id; self.item = item; self.kind = kind; self.shared = shared; self.provider = provider; self.businessID = businessID; self.businessSummary = businessSummary; self.website = website
    }
    let item: MKMapItem
    let kind: FacilityKind
    let shared: SharedPOI?
    let provider: String
    let businessID: String?
    let businessSummary: String?
    let website: URL?
}

struct WalkingRouteOption: Identifiable {
    let id: UUID
    let title: String
    let destinationName: String
    let stops: [DiscoveredPlace]
    let legs: [MKRoute]

    var distance: Double { legs.reduce(0) { $0 + $1.distance } }
    var duration: TimeInterval { legs.reduce(0) { $0 + $1.expectedTravelTime } }
}

@MainActor @Observable final class PlaceDiscovery: NSObject, @preconcurrency CLLocationManagerDelegate {
    var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.8826, longitude: -87.6226), span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    var places: [DiscoveredPlace] = []
    var status = "Search any city or neighborhood to begin."
    var isLoading = false
    var route: MKRoute?
    var itinerary: [MKRoute] = []
    var routeOptions: [WalkingRouteOption] = []
    var selectedRouteOptionID: UUID?
    var currentLocation: CLLocation?
    private let locationManager = CLLocationManager()
    private var generation = UUID()
    private var activeSearch: MKLocalSearch?
    private struct AreaSnapshot {
        let key: String
        let places: [DiscoveredPlace]
        let savedAt: Date
    }
    private var recentAreas: [AreaSnapshot] = []
    private func areaKey(_ region: MKCoordinateRegion) -> String {
        [region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta]
            .map { String(format: "%.4f", $0) }.joined(separator: ":")
    }
    override init() { super.init(); locationManager.delegate = self }

    func useLocation() {
        switch locationManager.authorizationStatus {
        case .notDetermined: locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways: locationManager.requestLocation()
        default: status = "Location access is unavailable. Search a place instead, or enable access in Settings."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        generation = UUID(); route = nil; itinerary = []; routeOptions = []; selectedRouteOptionID = nil; isLoading = false
        currentLocation = location
        region.center = location.coordinate
        status = "Location found. Tap Search this area to find facilities."
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "Could not locate you. You can still search a place." }

    func cancelPending() {
        generation = UUID()
        activeSearch?.cancel()
        activeSearch = nil
        isLoading = false
    }

    @discardableResult func findArea(_ query: String) async -> Bool {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let token = UUID(); generation = token; isLoading = true; route = nil
        defer { if generation == token { isLoading = false } }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard token == generation else { return false }
            guard let first = response.mapItems.first else { status = "No matching place found. Try a nearby city."; return false }
            region = MKCoordinateRegion(center: first.placemark.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
            places = []; status = "Area found. Tap Search this area to find facilities."
            return true
        } catch { if token == generation { status = "Place search failed. Check your connection and try again." }; return false }
    }

    @discardableResult func discover(kinds: Set<FacilityKind>, region searchRegion: MKCoordinateRegion) async -> Bool {
        cancelPending()
        let token = UUID(); generation = token; isLoading = true; route = nil
        let key = areaKey(searchRegion)
        let cached = recentAreas.first { $0.key == key && Date().timeIntervalSince($0.savedAt) < 300 }
        places = cached?.places ?? places.filter { place in
            let point = place.item.placemark.coordinate
            return abs(point.latitude - searchRegion.center.latitude) <= searchRegion.span.latitudeDelta / 2 &&
                abs(point.longitude - searchRegion.center.longitude) <= searchRegion.span.longitudeDelta / 2
        }
        status = cached == nil ? "Updating nearby stops…" : "Showing recent stops while checking for updates…"
        defer { if generation == token { isLoading = false } }
        guard !kinds.isEmpty else { status = "Select at least one facility filter."; return false }
        // Start both sources together; publish each as soon as it finishes.
        // Each task converts failures to values so one provider cannot cancel the other.
        var sharedFinished = false
        var cafeFinished = false
        var sharedSucceeded = false
        var receivedSharedPins = false
        var cafeSucceeded = false
        var sharedWarning = ""
        var cafeWarning = ""
        let sharedTask = Task { @MainActor in
            var result = await sharedStops(in: searchRegion)
            // A busy ingestion response is not an authoritative empty area.
            for _ in 0..<6 {
                guard token == generation, !Task.isCancelled else { return }
                guard case .success(let response) = result,
                      response.loading_state == "loading" || (response.loading_state == nil && response.warning != nil) else { break }
                let delay = min(max(response.retry_after_seconds ?? 15, 5), 60)
                let updates = response.pois.compactMap(\.place)
                receivedSharedPins = receivedSharedPins || !updates.isEmpty
                let incomingIDs = Set(updates.map(\.id))
                places.removeAll { incomingIDs.contains($0.id) }
                places += updates
                status = "Loading facilities in this area… " + (response.warning ?? "")
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard token == generation else { return }
                result = await sharedStops(in: searchRegion)
            }
            guard token == generation, !Task.isCancelled else { return }
            sharedFinished = true
            switch result {
            case .success(let response):
                sharedSucceeded = response.warning == nil
                let updates = response.pois.compactMap(\.place)
                receivedSharedPins = receivedSharedPins || !updates.isEmpty
                let incomingIDs = Set(updates.map(\.id))
                if sharedSucceeded { places.removeAll { $0.provider != "Mapbox" } }
                else { places.removeAll { incomingIDs.contains($0.id) } }
                places.insert(contentsOf: updates, at: 0)
                sharedWarning = (response.warning ?? "") + (response.truncated ? " Zoom in for all stops." : "")
            case .failure:
                sharedWarning = "Shared stops could not refresh; existing pins may be outdated."
            }
            status = cafeFinished ? sharedWarning : "Updating cafés… " + sharedWarning
        }
        let cafeTask = Task { @MainActor in
            let result = await commercialStops(in: searchRegion)
            guard token == generation, !Task.isCancelled else { return }
            cafeFinished = true
            switch result {
            case .success(let cafes):
                cafeSucceeded = true
                places.removeAll { $0.provider == "Mapbox" }
                places += cafes
            case .failure:
                cafeWarning = "Cafés could not refresh; existing pins may be outdated."
            }
            status = sharedFinished ? sharedWarning + " " + cafeWarning : "Loading nearby facilities… " + cafeWarning
        }
        await withTaskCancellationHandler {
            await sharedTask.value
            await cafeTask.value
        } onCancel: {
            sharedTask.cancel()
            cafeTask.cancel()
        }
        guard token == generation, !Task.isCancelled, sharedFinished, cafeFinished else { return false }
        let shared = places.filter { $0.provider != "Mapbox" }
        places.removeAll { cafe in
            cafe.provider == "Mapbox" && shared.contains { existing in
                existing.kind == .cafe && existing.item.name?.lowercased() == cafe.item.name?.lowercased() &&
                CLLocation(latitude: existing.item.placemark.coordinate.latitude, longitude: existing.item.placemark.coordinate.longitude)
                    .distance(from: CLLocation(latitude: cafe.item.placemark.coordinate.latitude, longitude: cafe.item.placemark.coordinate.longitude)) < 50
            }
        }
        if sharedSucceeded || receivedSharedPins {
            recentAreas.removeAll { $0.key == key }
            recentAreas.insert(AreaSnapshot(key: key, places: places, savedAt: Date()), at: 0)
            recentAreas = Array(recentAreas.prefix(8))
        }
        status = "\(places.count) possible stops. " + sharedWarning + " " + cafeWarning
        return sharedSucceeded && cafeSucceeded
    }

    private func sharedStops(in region: MKCoordinateRegion) async -> Result<SharedSearch, Error> {
        do { return .success(try await PausePathAPI.search(region)) }
        catch { return .failure(error) }
    }
    private func commercialStops(in region: MKCoordinateRegion) async -> Result<[DiscoveredPlace], Error> {
        do { return .success(try await PausePathAPI.cafes(region)) }
        catch { return .failure(error) }
    }

    func walkingDirections(to place: DiscoveredPlace, from origin: CLLocationCoordinate2D, via stops: [DiscoveredPlace] = []) async {
        await walkingDirections(to: place.item, destinationName: place.item.name ?? "Destination", from: origin, via: stops)
    }

    func walkingDirections(to destination: MKMapItem, destinationName: String, from origin: CLLocationCoordinate2D, via stops: [DiscoveredPlace] = []) async {
        let token = UUID(); generation = token; route = nil; itinerary = []; routeOptions = []; selectedRouteOptionID = nil; isLoading = true
        defer { if token == generation { isLoading = false } }
        var options: [WalkingRouteOption] = []
        var stopSets: [[DiscoveredPlace]] = [[]]
        for stop in stops { stopSets.append([stop]) }
        if stops.count >= 2 {
            for first in stops.indices {
                for second in stops.indices where second > first {
                    stopSets.append([stops[first], stops[second]])
                }
            }
        }
        if stops.count == 3 { stopSets.append(stops) }

        var directDistance: Double?
        for stopSet in stopSets {
            guard token == generation, !Task.isCancelled else { return }
            do {
                var legs: [MKRoute] = []
                var start = origin
                for waypoint in stopSet {
                    let request = MKDirections.Request()
                    request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                    request.destination = waypoint.item
                    request.transportType = .walking
                    let response = try await MKDirections(request: request).calculate()
                    guard let leg = response.routes.first else { throw RouteBuildError.noRoute }
                    legs.append(leg)
                    start = leg.polyline.walkingCoordinates.last?.mapCoordinate ?? waypoint.item.placemark.coordinate
                }
                let finalRequest = MKDirections.Request()
                finalRequest.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
                finalRequest.destination = destination
                finalRequest.transportType = .walking
                let finalResponse = try await MKDirections(request: finalRequest).calculate()
                guard let finalLeg = finalResponse.routes.first else { throw RouteBuildError.noRoute }
                legs.append(finalLeg)
                let stopNames = stopSet.map { $0.item.name ?? $0.kind.rawValue }
                let option = WalkingRouteOption(id: UUID(), title: stopSet.isEmpty ? "Direct" : "Via " + stopNames.joined(separator: " + "), destinationName: destinationName, stops: stopSet, legs: legs)
                if stopSet.isEmpty { directDistance = option.distance }
                if let directDistance, option.distance > directDistance * 2.25 { continue }
                options.append(option)
            } catch {
                // Keep successful alternatives if one stop combination cannot be routed.
                continue
            }
        }
        guard token == generation else { return }
        routeOptions = options.sorted { $0.distance < $1.distance }
        SavedRouteStore.save(routeOptions, origin: origin, destination: destination.placemark.coordinate)
        if let direct = routeOptions.first(where: { $0.stops.isEmpty }) {
            selectRouteOption(direct.id)
        } else if let first = routeOptions.first {
            selectRouteOption(first.id)
        } else {
            status = "No walking route was found for this destination and stop combination. Try another destination or fewer stops."
            return
        }
        status = routeOptions.count == 1
            ? "One walking route is available. Stop access and opening hours are unverified."
            : "\(routeOptions.count) walking route options found. Compare time and distance before choosing. Stop access and opening hours are unverified."
    }

    func selectRouteOption(_ id: UUID) {
        guard let option = routeOptions.first(where: { $0.id == id }) else { return }
        selectedRouteOptionID = option.id
        itinerary = option.legs
        route = option.legs.first
    }

    private enum RouteBuildError: Error { case noRoute }
}
