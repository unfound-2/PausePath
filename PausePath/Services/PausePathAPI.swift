import Foundation
import Observation
import Security
import MapKit
import AuthenticationServices

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
    var appleUserID: String? = nil
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
    enum SessionState: Equatable {
        case signedOut
        case checking
        case ready
        case temporarilyUnavailable
    }

    static let shared = PausePathAccount()
    private var session: AuthSession?
    private var expiration = Date.distantPast
    private var revision = UUID()
    private var refreshTask: Task<AuthSession, Error>?
    private var appleChallenge: AppleSignInChallenge?
    var email: String? { session?.user.email }
    var isSignedIn: Bool { session != nil }
    var sessionState: SessionState = .signedOut
    var appleCredentialStatusText = "No Apple credential is linked"
    var sessionStatusText: String {
        switch sessionState {
        case .signedOut: "Not signed in"
        case .checking: "Checking saved account…"
        case .ready: "Community account ready"
        case .temporarilyUnavailable: "Saved account; community service is temporarily unavailable"
        }
    }
    var userID: String? { session?.user.id }
    func markCommunitySessionAvailable() {
        guard session != nil else { return }
        sessionState = .ready
    }
    func markCommunityServiceUnavailable() {
        guard session != nil else { return }
        sessionState = .temporarilyUnavailable
        message = "Your account is saved, but PausePath could not reach the community service. Check your connection and try again."
    }
    var message = "Browse and plan without an account. Sign in only to contribute reports."
    var busy = false
    var appleProvidedName: String?
    private init() {
        if let data = SessionKeychain.read(), let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = saved
            expiration = Date(timeIntervalSince1970: saved.expires_at ?? 0)
            sessionState = .checking
        }
    }
    private func validateAccessToken(_ token: String) async throws {
        var request = URLRequest(url: URL(string: "user", relativeTo: ServiceConfiguration.auth)!)
        request.httpMethod = "GET"
        request.setValue(ServiceConfiguration.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await ServiceHTTP.send(request)
    }
    /// Validate a Keychain-restored backend session without discarding it on transient network errors.
    func restoreSessionIfNeeded() async {
        guard session != nil else { sessionState = .signedOut; return }
        sessionState = .checking
        do {
            var token = try await accessToken()
            do {
                try await validateAccessToken(token)
            } catch let error as ServiceFailure where error.status == 401 {
                token = try await accessToken(forceRefresh: true)
                try await validateAccessToken(token)
            }
            sessionState = .ready
            message = "Your PausePath account is ready for community features."
        } catch let error as ServiceFailure where [400, 401, 403].contains(error.status) {
            if session != nil {
                session = nil
                SessionKeychain.clear()
                revision = UUID()
            }
            sessionState = .signedOut
            message = "Your saved session expired. Sign in with Apple again to use community features."
        } catch {
            // A network outage or timeout must not erase a potentially valid saved session.
            sessionState = .temporarilyUnavailable
            message = "Your account is saved, but PausePath could not reach the community service. Check your connection and try again."
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
            expires_at: expiry, expires_in: value.expires_in, user: value.user, appleUserID: value.appleUserID)
        try SessionKeychain.write(JSONEncoder().encode(saved))
        session = saved; expiration = Date(timeIntervalSince1970: expiry)
        sessionState = .ready
    }
    func prepareAppleSignIn(_ request: ASAuthorizationAppleIDRequest) {
        revision = UUID(); refreshTask?.cancel(); refreshTask = nil
        appleChallenge = nil
        do {
            let challenge = try AppleSignInChallenge()
            appleChallenge = challenge
            request.requestedScopes = [.email, .fullName]
            request.nonce = challenge.hashedNonce
            request.state = challenge.state
            busy = true; message = "Confirm Sign in with Apple to continue."
        } catch {
            busy = false; message = "Could not securely start Apple sign-in. Please try again."
        }
    }
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        let current = revision
        let challenge = appleChallenge
        appleChallenge = nil // Never reuse a challenge, including after a failed exchange.
        defer { if current == revision { busy = false } }
        do {
            let authorization = try result.get()
            guard let challenge,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  challenge.accepts(state: credential.state),
                  let bytes = credential.identityToken,
                  let idToken = String(data: bytes, encoding: .utf8), !idToken.isEmpty else {
                throw ServiceFailure(status: 400, message: "Apple sign-in expired or could not be verified. Please try again.")
            }
            let data = try await authRequest("token?grant_type=id_token", body: [
                "provider": "apple", "id_token": idToken, "nonce": challenge.nonce])
            guard current == revision else { return }
            var value = try JSONDecoder().decode(AuthSession.self, from: data)
            value.appleUserID = credential.user
            appleProvidedName = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                .flatMap { $0.isEmpty ? nil : $0 }
            appleCredentialStatusText = "Apple sign-in completed"
            try install(value)
            sessionState = .ready
            message = "Signed in with Apple. You can now submit community reports."
        } catch let error as ASAuthorizationError where error.code == .canceled {
            if current == revision { message = "Sign-in cancelled. You can continue exploring without an account." }
        } catch {
            if current == revision { message = error.localizedDescription }
        }
    }
    func checkAppleCredential() async {
        guard let appleID = session?.appleUserID else {
            appleCredentialStatusText = "No Apple credential is linked"
            return
        }
        let current = revision
        do {
            let state: ASAuthorizationAppleIDProvider.CredentialState = try await withCheckedThrowingContinuation { continuation in
                ASAuthorizationAppleIDProvider().getCredentialState(forUserID: appleID) { state, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: state) }
                }
            }
            guard current == revision else { return }
            if state == .authorized {
                appleCredentialStatusText = "Apple credential authorized"
            } else if state == .revoked || state == .notFound {
                appleCredentialStatusText = "Apple credential needs sign-in again"
                await signOut()
                message = "Apple sign-in is no longer authorized. Sign in again to contribute."
            } else {
                appleCredentialStatusText = "Apple credential status is unavailable"
            }
        } catch {
            // A temporary Apple/network failure does not erase a valid session.
            appleCredentialStatusText = "Apple credential status could not be checked"
        }
    }
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let session else { throw ServiceFailure(status: 401, message: "Sign in from the Account tab to submit a community report.") }
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
            var value = try await task.value
            value.appleUserID = session.appleUserID
            guard revision == current else { throw CancellationError() }
            try install(value); refreshTask = nil
            return value.access_token
        } catch {
            if revision == current {
                refreshTask = nil
                if let error = error as? ServiceFailure, [400,401,403].contains(error.status) {
                    self.session = nil; SessionKeychain.clear(); revision = UUID()
                    sessionState = .signedOut
                    message = "Your session expired. Please sign in again."
                }
            }
            throw error
        }
    }
    func signOut() async {
        let old = session?.access_token
        revision = UUID(); refreshTask?.cancel(); refreshTask = nil
        appleChallenge = nil; busy = false
        session = nil; SessionKeychain.clear()
        sessionState = .signedOut
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
    let loading_state: String?
    let retry_after_seconds: Int?
    let tiles_ready: Int?
    let tiles_total: Int?
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
struct WalkingCommunity: Codable, Identifiable {
    let id: UUID
    let name: String
    let invite_code: String
    let created_at: String?
    let member_count: Int
    let my_display_name: String
    let members: [String]?
}
struct WalkingChallengeMember: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let amount: Double
}
struct WalkingCommunityChallenge: Decodable, Identifiable {
    let created_at: String
    var startDate: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: created_at) { return date }
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: created_at)
    }
    let id: UUID
    let community_id: UUID
    let name: String
    let metric: String
    let target: Double
    let my_progress: Double?
    let leaderboard: [WalkingChallengeMember]
}
private struct CommunityListResponse: Decodable { let communities: [WalkingCommunity] }
private struct ChallengeListResponse: Decodable { let challenges: [WalkingCommunityChallenge] }

@MainActor enum PausePathAPI {
    static func request(_ path: String, body: [String: Any]? = nil, retry: Bool = true, requiresAccount: Bool = false) async throws -> Data {
        let account = PausePathAccount.shared
        let user = account.userID
        let token = requiresAccount ? try await account.accessToken() : nil
        var request = URLRequest(url: ServiceConfiguration.api.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        do {
            let data = try await ServiceHTTP.send(request)
            try Task.checkCancellation()
            guard !requiresAccount || account.userID == user else { throw CancellationError() }
            if requiresAccount { account.markCommunitySessionAvailable() }
            return data
        } catch let error as ServiceFailure where error.status == 401 && requiresAccount && retry && account.userID == user {
            _ = try await account.accessToken(forceRefresh: true)
            return try await self.request(path, body: body, retry: false, requiresAccount: requiresAccount)
        } catch let error as ServiceFailure {
            if requiresAccount, (500..<600).contains(error.status) { account.markCommunityServiceUnavailable() }
            throw error
        } catch {
            if requiresAccount, error is URLError { account.markCommunityServiceUnavailable() }
            throw error
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

    static func communities() async throws -> [WalkingCommunity] {
        let data = try await request("api/v1/communities", requiresAccount: true)
        return try JSONDecoder().decode(CommunityListResponse.self, from: data).communities
    }
    static func createCommunity(name: String, username: String) async throws -> WalkingCommunity {
        let data = try await request("api/v1/communities", body: ["name": name, "display_name": username], requiresAccount: true)
        return try JSONDecoder().decode(WalkingCommunity.self, from: data)
    }
    static func joinCommunity(code: String, username: String) async throws -> WalkingCommunity {
        let data = try await request("api/v1/communities/join", body: ["invite_code": code, "display_name": username], requiresAccount: true)
        return try JSONDecoder().decode(WalkingCommunity.self, from: data)
    }
    static func updateCommunityUsername(_ username: String) async throws {
        _ = try await request("api/v1/communities/username", body: ["display_name": username], requiresAccount: true)
    }
    static func challenges(in community: UUID) async throws -> [WalkingCommunityChallenge] {
        let data = try await request("api/v1/communities/\(community.uuidString)/challenges", requiresAccount: true)
        return try JSONDecoder().decode(ChallengeListResponse.self, from: data).challenges
    }
    static func createChallenge(in community: UUID, name: String, metric: String, target: Double) async throws {
        _ = try await request("api/v1/communities/\(community.uuidString)/challenges",
            body: ["name": name, "metric": metric, "target": target], requiresAccount: true)
    }
    static func updateChallengeProgress(_ challenge: UUID, amount: Double) async throws {
        _ = try await request("api/v1/challenges/\(challenge.uuidString)/progress", body: ["amount": amount], requiresAccount: true)
    }
    static func deleteChallengeProgress(_ challenge: UUID) async throws {
        _ = try await request("api/v1/challenges/\(challenge.uuidString)/progress/delete", body: [:], requiresAccount: true)
    }
    static func syncChallengeProgress(walks: [TrackedWalk]) async throws {
        guard UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") else { return }
        let groups = try await communities()
        for group in groups {
            for challenge in try await challenges(in: group.id) {
                guard UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") else { return }
                guard let start = challenge.startDate else {
                    throw ServiceFailure(status: 422, message: "This challenge has an invalid start date. Progress has not been changed.")
                }
                let total = ChallengeProgressCalculator.total(metric: challenge.metric, walks: walks, from: start, until: Date())
                try await updateChallengeProgress(challenge.id, amount: min(total, 100000))
                // An opt-out during the request must not leave that upload visible.
                if !UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") {
                    try await deleteChallengeProgress(challenge.id)
                    return
                }
            }
        }
    }

    static func clearChallengeProgress() async throws {
        for group in try await communities() {
            for challenge in try await challenges(in: group.id) {
                try await deleteChallengeProgress(challenge.id)
            }
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
