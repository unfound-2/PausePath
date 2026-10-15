import Foundation
import Observation
import Security
import MapKit

// Public client configuration. Database credentials and Mapbox tokens stay on Render.
enum ServiceConfiguration {
    static let api = URL(string: "https://pausepath-api.onrender.com")!
    static let auth = URL(string: "https://yrigwegtumlybprrhdgv.supabase.co/auth/v1/")!
    static let publishableKey = "sb_publishable_WGAuMlPt8ACMq17OAyVOQA_0EUV74At"
}
struct ServiceFailure: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}
enum ServiceHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"] as? String ?? object?["msg"] as? String ?? object?["message"] as? String
                ?? object?["error_description"] as? String
            throw ServiceFailure(status: response.statusCode, message: detail ?? "Service unavailable (\(response.statusCode)). Please try again.")
        }
        return data
    }
}
private struct AuthSession: Codable {
    let access_token: String
    let refresh_token: String
    let expires_at: Double?
    let expires_in: Double?
    let user: User
    struct User: Codable { let id: String; let email: String? }
}
private enum SessionKeychain {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "PausePath.Supabase", kSecAttrAccount as String: "session"] }
    static func read() -> Data? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    static func write(_ data: Data) throws {
        let updates = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ServiceFailure(status: Int(status), message: "Could not securely save your session. Unlock the device and try again.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

@MainActor @Observable final class PausePathAccount {
    static let shared = PausePathAccount()
    private var session: AuthSession?
    private var expiration = Date.distantPast
    private var revision = UUID()
    private var refreshTask: Task<AuthSession, Error>?
    var email: String? { session?.user.email }
    var isSignedIn: Bool { session != nil }
    var userID: String? { session?.user.id }
    var message = "Sign in to use shared stops and community reports."
    var busy = false
    private init() {
        if let data = SessionKeychain.read(), let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = saved
            expiration = Date(timeIntervalSince1970: saved.expires_at ?? 0)
        }
    }
    private func authRequest(_ path: String, body: [String: Any], token: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: ServiceConfiguration.auth)!)
        request.httpMethod = "POST"
        request.setValue(ServiceConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await ServiceHTTP.send(request)
    }
    private func install(_ value: AuthSession) throws {
        // Normalize expiry so a restored session never extends the original lifetime.
        let expiry = value.expires_at ?? Date().timeIntervalSince1970 + (value.expires_in ?? 0)
        let saved = AuthSession(access_token: value.access_token, refresh_token: value.refresh_token,
            expires_at: expiry, expires_in: value.expires_in, user: value.user)
        try SessionKeychain.write(JSONEncoder().encode(saved))
        session = saved; expiration = Date(timeIntervalSince1970: expiry)
    }
    func signIn(email: String, password: String, create: Bool) async {
        guard !busy else { return }; busy = true
        revision = UUID(); let current = revision
        refreshTask?.cancel(); refreshTask = nil
        defer { busy = false }
        do {
            let data = try await authRequest(create ? "signup" : "token?grant_type=password", body: ["email": email, "password": password])
            guard revision == current else { return }
            if let result = try? JSONDecoder().decode(AuthSession.self, from: data) {
                try install(result); message = "Connected. Shared stops are available in Explore."
            } else if create {
                message = "Check your email to confirm your account, then return here and sign in."
            } else { throw URLError(.cannotParseResponse) }
        } catch { message = error.localizedDescription }
    }
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session else { throw ServiceFailure(status: 401, message: "Sign in from the Account tab to use shared stops.") }
        if !forceRefresh, expiration.timeIntervalSinceNow > 60 { return session.access_token }
        let current = revision
        let task: Task<AuthSession, Error>
        if let existing = refreshTask { task = existing }
        else {
            task = Task {
                let data = try await self.authRequest("token?grant_type=refresh_token", body: ["refresh_token": session.refresh_token])
                return try JSONDecoder().decode(AuthSession.self, from: data)
            }
            refreshTask = task
        }
        do {
            let value = try await task.value
            guard revision == current else { throw CancellationError() }
            try install(value); refreshTask = nil
            return value.access_token
        } catch {
            if revision == current {
                refreshTask = nil
                if let error = error as? ServiceFailure, [400,401,403].contains(error.status) {
                    self.session = nil; SessionKeychain.clear(); revision = UUID()
                    message = "Your session expired. Please sign in again."
                }
            }
            throw error
        }
    }
    func signOut() async {
        let old = session?.access_token
        revision = UUID(); refreshTask?.cancel(); refreshTask = nil
        session = nil; SessionKeychain.clear()
        message = "Signed out on this device."
        if let old {
            do { _ = try await authRequest("logout?scope=local", body: [:], token: old) }
            catch { message = "Signed out locally. The server could not be reached to revoke the session." }
        }
    }
}

extension FacilityKind {
    var apiCategory: String {
        switch self { case .bench: "bench"; case .bathroom: "toilet"; case .fountain: "drinking_water"; case .cafe: "cafe" }
    }
    static func fromAPI(_ category: String) -> FacilityKind? { allCases.first { $0.apiCategory == category } }
}
struct APIPoint: Decodable { let coordinates: [Double] }
struct SharedPOI: Decodable, Identifiable {
    let id: UUID
    let name: String?
    let category: String
    let location: APIPoint
    let confidence_score: Double
    let source: String
    let is_active: Bool?
    let closed_until: String?
    var unavailable: Bool {
        if is_active == false { return true }
        guard let closed_until else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: closed_until) ?? ISO8601DateFormatter().date(from: closed_until)
        return date.map { $0 > Date() } ?? true
    }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: location.coordinates[1], longitude: location.coordinates[0]) }
    var place: DiscoveredPlace? {
        guard location.coordinates.count == 2, let kind = FacilityKind.fromAPI(category) else { return nil }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate)); item.name = name ?? kind.rawValue
        return DiscoveredPlace(id: id, item: item, kind: kind, shared: self, provider: source == "osm" ? "OpenStreetMap" : "PausePath community")
    }
}
struct SharedSearch: Decodable {
    let pois: [SharedPOI]
    let warning: String?
    let truncated: Bool
    let attribution: String
}
struct CuratedBreak: Decodable, Identifiable {
    var id: UUID { poi.id }
    let target_distance_meters: Double
    let distance_marker_meters: Double
    let arrival_at: String
    let hours_status: String
    let poi: SharedPOI
}
struct CuratedResponse: Decodable {
    let properties: Properties
    struct Properties: Decodable {
        let break_points: [CuratedBreak]
        let unfilled_targets_meters: [Double]
        let warnings: [String]
        let total_distance_with_detours_meters: Double
    }
}
@MainActor enum PausePathAPI {
    static func request(_ path: String, body: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        let account = PausePathAccount.shared
        let user = account.userID
        let token = try await account.accessToken()
        var request = URLRequest(url: ServiceConfiguration.api.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let data = try await ServiceHTTP.send(request)
            try Task.checkCancellation()
            guard account.userID == user else { throw CancellationError() }
            return data
        } catch let error as ServiceFailure where error.status == 401 && retry && account.userID == user {
            _ = try await account.accessToken(forceRefresh: true)
            return try await self.request(path, body: body, retry: false)
        }
    }
    static func bounds(_ region: MKCoordinateRegion) throws -> [String: Double] {
        let lat = region.span.latitudeDelta / 2, lon = region.span.longitudeDelta / 2
        let c = region.center
        guard lat > 0, lon > 0, lat <= 0.049, lon <= 0.049,
              c.latitude-lat >= -85, c.latitude+lat <= 85, c.longitude-lon >= -180, c.longitude+lon <= 180 else {
            throw ServiceFailure(status: 422, message: "Zoom in to load shared stops. Near the date line, search each side separately.")
        }
        return ["south": c.latitude-lat, "north": c.latitude+lat, "west": c.longitude-lon, "east": c.longitude+lon]
    }
    static func search(_ region: MKCoordinateRegion) async throws -> SharedSearch {
        let data = try await request("api/v1/pois/search", body: bounds(region))
        return try JSONDecoder().decode(SharedSearch.self, from: data)
    }
    static func cafes(_ region: MKCoordinateRegion) async throws -> [DiscoveredPlace] {
        let b = try bounds(region)
        let body: [String: Any] = ["category":"coffee", "limit": 25,
            "proximity": ["type":"Point", "coordinates":[region.center.longitude,region.center.latitude]],
            "bbox":[b["west"]!, b["south"]!, b["east"]!, b["north"]!]]
        let data = try await request("api/v1/commercial/mapbox/category", body: body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let collection = object?["data"] as? [String: Any]
        let features = collection?["features"] as? [[String: Any]] ?? []
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Double], coordinates.count == 2,
                  let properties = feature["properties"] as? [String: Any] else { return nil }
            let metadata = properties["metadata"] as? [String: Any]
            if let status = (properties["operational_status"] ?? metadata?["operational_status"]) as? String, status.lowercased().contains("closed") { return nil }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: coordinates[1], longitude: coordinates[0])))
            item.name = properties["name"] as? String ?? "Café"
            let operational = properties["operational_status"] as? String
            let summary = operational.map { "Business status: " + $0 + ". Opening hours at arrival are unknown." }
            let website = (metadata?["website"] as? String).flatMap(URL.init(string:))
            return DiscoveredPlace(item: item, kind: .cafe, provider: "Mapbox", businessID: properties["mapbox_id"] as? String,
                businessSummary: summary, website: website?.scheme == "https" ? website : nil)
        }
    }
    static func curate(_ walk: GeneratedWalk, allowUnknown: Bool) async throws -> CuratedResponse {
        // Explicit request shares route geometry and preferences; Health speed is never uploaded.
        let coordinates = walk.paths.flatMap { $0 }.map { [$0.longitude, $0.latitude] }
        let categories = walk.preferences.facilities.sorted { $0.apiCategory < $1.apiCategory }.map(\.apiCategory)
        let body: [String: Any] = ["geometry": ["type":"LineString", "coordinates": coordinates],
            "movement_type":"walk", "departure_at": ISO8601DateFormatter().string(from: walk.preferences.departure),
            "preferences": ["target_break_interval_meters": walk.preferences.maximumRestGapMeters,
                "prioritized_categories": categories.isEmpty ? ["bench"] : categories,
                "allow_unknown_hours": allowUnknown]]
        let data = try await request("api/v1/routes/curate", body: body)
        return try JSONDecoder().decode(CuratedResponse.self, from: data)
    }
}
