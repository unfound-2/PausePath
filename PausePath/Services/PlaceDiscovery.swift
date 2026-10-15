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

@MainActor @Observable final class PlaceDiscovery: NSObject, @preconcurrency CLLocationManagerDelegate {
    var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 41.8826, longitude: -87.6226), span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    var places: [DiscoveredPlace] = []
    var status = "Search any city or neighborhood to begin."
    var isLoading = false
    var route: MKRoute?
    private let locationManager = CLLocationManager()
    private var generation = UUID()
    private var activeSearch: MKLocalSearch?
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
        generation = UUID(); places = []; route = nil; isLoading = false
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
        status = "Updating nearby stops…"
        defer { if generation == token { isLoading = false } }
        guard !kinds.isEmpty else { status = "Select at least one facility filter."; return false }
        if PausePathAccount.shared.isSignedIn {
            do {
                let response = try await PausePathAPI.search(searchRegion)
                guard token == generation, !Task.isCancelled else { return false }
                var stops = response.pois.compactMap(\.place)
                var commercialWarning = ""
                do {
                    let cafes = try await PausePathAPI.cafes(searchRegion)
                    // Prefer reportable OSM/community records for duplicate cafés.
                    stops += cafes.filter { cafe in !stops.contains { existing in
                        existing.kind == .cafe && existing.item.name?.lowercased() == cafe.item.name?.lowercased() &&
                        CLLocation(latitude: existing.item.placemark.coordinate.latitude, longitude: existing.item.placemark.coordinate.longitude)
                            .distance(from: CLLocation(latitude: cafe.item.placemark.coordinate.latitude, longitude: cafe.item.placemark.coordinate.longitude)) < 50
                    } }
                } catch { commercialWarning = " Mapbox cafés unavailable; shared stops are shown." }
                guard token == generation, !Task.isCancelled else { return false }
                places = stops
                status = "\(stops.count) shared/provider stops. Hours and seating need confirmation." + (response.warning.map { " " + $0 } ?? "") + commercialWarning + (response.truncated ? " Zoom in for all stops." : "")
                return true
            } catch {
                guard token == generation, !Task.isCancelled else { return false }
                places = []; status = error.localizedDescription
                return false
            }
        }
        var found: [DiscoveredPlace] = []
        var failures = 0
        for kind in kinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard token == generation, !Task.isCancelled else { return false }
            let request = MKLocalSearch.Request()
            request.region = searchRegion
            switch kind {
            case .bench: request.naturalLanguageQuery = "public benches seating"
            case .bathroom: request.naturalLanguageQuery = "public restrooms"
            case .fountain: request.naturalLanguageQuery = "drinking water fountains"
            case .cafe: request.naturalLanguageQuery = "cafes"
            }
            do {
                let search = MKLocalSearch(request: request)
                activeSearch = search
                let response = try await search.start()
                guard token == generation, !Task.isCancelled else { return false }
                activeSearch = nil
                found += response.mapItems.filter {
                    let c = $0.placemark.coordinate
                    return abs(c.latitude - searchRegion.center.latitude) <= searchRegion.span.latitudeDelta / 2 && abs(c.longitude - searchRegion.center.longitude) <= searchRegion.span.longitudeDelta / 2
                }.map { DiscoveredPlace(item: $0, kind: kind) }
            } catch {
                guard token == generation, !Task.isCancelled else { return false }
                activeSearch = nil
                failures += 1
            }
        }
        guard token == generation, !Task.isCancelled else { return false }
        places = found
        status = "\(found.count) possible stops. Facility type, seating and hours need confirmation.\(failures > 0 ? " Some searches failed; retry when connected." : "")"
        return true
    }

    func walkingDirections(to place: DiscoveredPlace, from origin: CLLocationCoordinate2D) async {
        let token = UUID(); generation = token; route = nil; isLoading = true
        defer { if token == generation { isLoading = false } }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = place.item; request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            guard token == generation else { return }
            route = response.routes.first
            status = route == nil ? "No walking route available here." : "Walking directions from map center. Slope, seating gaps and opening hours are unverified."
        } catch { if token == generation { status = "Walking directions unavailable here. Try another stop." } }
    }
}
