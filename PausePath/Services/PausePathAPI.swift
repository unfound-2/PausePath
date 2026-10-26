import Foundation
import Observation
import Security
import MapKit
import AuthenticationServices
import OSLog

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

    /// Only errors that prove the backend credential is invalid may erase a saved session.
    var confirmsInvalidSession: Bool {
        if status == 401 { return true }
        guard status == 400 else { return false }
        let detail = message.lowercased()
        return detail.contains("invalid refresh token")
            || detail.contains("refresh_token_not_found")
            || detail.contains("refresh token not found")
            || detail.contains("refresh token already used")
    }
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
    enum SessionState: Equatable {
        case signedOut
        case checking
        case ready
        case temporarilyUnavailable
    }

    static let shared = PausePathAccount()
    static let signedOutMessage = "Browse without signing in. Sign in with Apple for community features."
    private var session: AuthSession?
    private var expiration = Date.distantPast
    private var revision = UUID()
    private var refreshTask: Task<AuthSession, Error>?
    private var appleChallenge: AppleSignInChallenge?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PausePath", category: "Account")
    var email: String? { session?.user.email }
    var isSignedIn: Bool { session != nil }
    var sessionState: SessionState = .signedOut
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
    var message = PausePathAccount.signedOutMessage
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
    // Apple establishes the Supabase session at sign-in. There is no periodic Apple
    // credential-state check; the backend session is the source of truth afterward.
    /// Validate a Keychain-restored backend session without discarding it on transient network errors.
    func restoreSessionIfNeeded() async {
        guard session != nil else { sessionState = .signedOut; return }
        let current = revision
        sessionState = .checking
        do {
            var token = try await accessToken()
            guard current == revision else { return }
            do {
                try await validateAccessToken(token)
            } catch let error as ServiceFailure where error.status == 401 {
                token = try await accessToken(forceRefresh: true)
                guard current == revision else { return }
                try await validateAccessToken(token)
            }
            guard current == revision else { return }
            sessionState = .ready
            message = "Your PausePath account is ready for community features."
        } catch let error as ServiceFailure where error.confirmsInvalidSession {
            guard current == revision else { return }
            if session != nil {
                session = nil
                SessionKeychain.clear()
                revision = UUID()
            }
            sessionState = .signedOut
            message = "Your saved session expired. Sign in with Apple again to use community features."
        } catch {
            guard current == revision else { return }
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
            expires_at: expiry, expires_in: value.expires_in, user: value.user)
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
            let diagnostic = error as NSError
            logger.error("Could not create Apple sign-in challenge (domain: \(diagnostic.domain, privacy: .public), code: \(diagnostic.code, privacy: .public))")
        }
    }
    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        var current = revision
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
            let value = try JSONDecoder().decode(AuthSession.self, from: data)
            // Invalidate credential checks started while this sign-in was in progress.
            revision = UUID()
            current = revision
            appleProvidedName = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
                .flatMap { $0.isEmpty ? nil : $0 }
            try install(value)
            sessionState = .ready
            message = "Signed in with Apple. You can now submit community reports."
        } catch let error as ASAuthorizationError where error.code == .canceled {
            if current == revision { message = "Sign-in cancelled. You can continue exploring without an account." }
        } catch let error as ServiceFailure {
            logger.error("Apple sign-in exchange failed with HTTP status \(error.status, privacy: .public)")
            if current == revision { message = error.localizedDescription }
        } catch {
            let diagnostic = error as NSError
            logger.error("Apple sign-in failed (domain: \(diagnostic.domain, privacy: .public), code: \(diagnostic.code, privacy: .public))")
            if current == revision { message = error.localizedDescription }
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
            let value = try await task.value
            guard revision == current else { throw CancellationError() }
            try install(value); refreshTask = nil
            return value.access_token
        } catch {
            if revision == current {
                refreshTask = nil
                if let error = error as? ServiceFailure, error.confirmsInvalidSession {
                    self.session = nil; SessionKeychain.clear(); revision = UUID()
                    sessionState = .signedOut
                    message = "Your session expired. Please sign in again."
                }
            }
            throw error
        }
    }
    // MARK: Account deletion (App Store Review Guideline 5.1.1(v))
    private var deletionChallenge: AppleSignInChallenge?
    var deletingAccount = false
    var deletionMessage: String?

    /// Re-confirms with Apple so the server can revoke this app's Apple tokens.
    func prepareAccountDeletion(_ request: ASAuthorizationAppleIDRequest) {
        deletionChallenge = try? AppleSignInChallenge()
        request.requestedScopes = []
        if let challenge = deletionChallenge {
            request.nonce = challenge.hashedNonce
            request.state = challenge.state
        }
        deletionMessage = nil
    }

    /// Returns true once the server confirmed deletion and local account state is cleared.
    @discardableResult func deleteAccount(_ result: Result<ASAuthorization, Error>) async -> Bool {
        let challenge = deletionChallenge
        deletionChallenge = nil
        guard !deletingAccount, let owner = userID else { return false }
        var body: [String: Any] = [:]
        do {
            let authorization = try result.get()
            guard let challenge,
                  let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  challenge.accepts(state: credential.state) else {
                deletionMessage = "Apple confirmation expired. Please try again."
                return false
            }
            if let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }), !code.isEmpty {
                body["apple_authorization_code"] = code
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            deletionMessage = "Deletion cancelled. Your account was not changed."
            return false
        } catch {
            deletionMessage = "Apple could not confirm your identity. Your account was not changed."
            return false
        }
        deletingAccount = true
        defer { deletingAccount = false }
        do {
            _ = try await PausePathAPI.request("api/v1/account/delete", body: body, requiresAccount: true)
        } catch {
            guard userID == owner else { return false }
            deletionMessage = (error as? ServiceFailure)?.message
                ?? "PausePath could not reach the server. Your account was not deleted; check your connection and try again."
            return false
        }
        guard userID == owner else { return false }
        clearLocalAccountState(owner: owner)
        message = "Your PausePath account and community data were deleted."
        deletionMessage = nil
        return true
    }

    /// Clears everything on this device that belongs to the signed-in account.
    /// Walks and Health readings saved only on this iPhone are kept.
    private func clearLocalAccountState(owner: String) {
        revision = UUID(); refreshTask?.cancel(); refreshTask = nil
        appleChallenge = nil; busy = false
        session = nil; SessionKeychain.clear()
        sessionState = .signedOut
        let defaults = UserDefaults.standard
        for key in ["pausepath.shareChallengeProgress", "pausepath.shareProgressOwner",
                    "pausepath.walkReminders.\(owner)", "pausepath.pendingProgressRemoval.\(owner)",
                    "pausepath.communitySubmissionDraft.v1", "pausepath.pendingCommunityInvite",
                    "pausepath.pendingInbox"] {
            defaults.removeObject(forKey: key)
        }
        SocialActivityStore.shared.reset()
    }

    func signOut() async {
        UserDefaults.standard.set(false, forKey: "pausepath.shareChallengeProgress")
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
struct APIPoint: Codable { let coordinates: [Double] }
// Only known scalar metadata is displayed; unfamiliar shapes stay unknown.
struct POIMetadataValue: Decodable {
    let text: String?
    let flag: Bool?
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        text = try? value.decode(String.self)
        flag = try? value.decode(Bool.self)
    }
}
struct StopAccessibility: Codable {
    let wheelchair_accessible: Bool?
    let backrest: Bool?
    let shaded: Bool?
    let access: String?
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: POIMetadataValue].self)
        wheelchair_accessible = values["wheelchair_accessible"]?.flag
        backrest = values["backrest"]?.flag
        shaded = values["shaded"]?.flag
        access = values["access"]?.text
    }
    var summary: String {
        func value(_ flag: Bool?) -> String { flag.map { $0 ? "Yes" : "No" } ?? "Unknown" }
        return "Wheelchair access: \(value(wheelchair_accessible)) · Backrest: \(value(backrest)) · Shade: \(value(shaded)) · Access: \(access ?? "unknown")"
    }
}

struct SharedPOI: Codable, Identifiable {
    let id: UUID
    let name: String?
    let category: String
    let location: APIPoint
    let confidence_score: Double
    let source: String
    let is_active: Bool?
    let closed_until: String?
    let attributes: StopAccessibility?
    let operating_hours: FacilityHours?
    let last_verified_at: String?
    let source_updated_at: String?
    let last_reported_at: String?
    let last_report_type: String?
    let hours_status: String?
    let hours_evaluated_at: String?
    var accessDescription: String { attributes?.access ?? "unknown" }
    var restrictedAccess: Bool { ["private", "customers"].contains(accessDescription) }
    var reportedUnavailable: Bool {
        guard let type = last_report_type, type != "confirm_exists", let report = FacilityHours.date(last_reported_at) else { return false }
        return report > (FacilityHours.date(last_verified_at) ?? .distantPast)
    }
    func openAtArrival(_ date: Date, duration: TimeInterval = 300) -> Bool? {
        if unavailable || reportedUnavailable { return false }
        return operating_hours?.isOpen(at: date, duration: duration)
    }
    func availabilityDescription(at date: Date) -> String {
        if restrictedAccess { return accessDescription == "private" ? "Private access" : "Customers only" }
        switch openAtArrival(date) {
        case true: return "Listed open at expected arrival"
        case false: return "Closed or reported unavailable at arrival"
        case nil: return "Opening hours at arrival unknown"
        }
    }
    var hoursDescription: String {
        if unavailable { return "Reported unavailable" }
        guard let raw = operating_hours?.raw, !raw.isEmpty else { return "Opening hours unknown" }
        return raw == "24/7" ? "Listed as open 24 hours · not live-verified" : "Listed hours: " + raw + " · current status unknown"
    }
    private func attribute(_ key: String) -> String {
        let flag: Bool?
        switch key {
        case "wheelchair_accessible": flag = attributes?.wheelchair_accessible
        case "backrest": flag = attributes?.backrest
        case "shaded": flag = attributes?.shaded
        default: flag = nil
        }
        guard let flag else { return "Unknown" }
        return flag ? "Yes" : "No"
    }
    var accessibilityDescription: String { attribute("wheelchair_accessible") }
    var backrestDescription: String { attribute("backrest") }
    var shadeDescription: String { attribute("shaded") }
    var verificationDescription: String {
        guard let raw = last_verified_at else { return "Unknown" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
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
    var pois: [SharedPOI]
    var next_cursor: String?
    let warning: String?
    var truncated: Bool
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
struct CommunityNextWalk: Codable, Sendable {
    let id: UUID
    let title: String
    let starts_at: String
}
struct WalkingCommunity: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let invite_code: String
    let created_at: String?
    let is_owner: Bool?
    let member_count: Int
    let my_display_name: String
    let members: [String]?
    let active_goal_count: Int?
    let next_walk: CommunityNextWalk?
    let summary_available: Bool?
}
struct WalkingChallengeMember: Decodable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let amount: Double
}
struct WalkingCommunityChallenge: Decodable, Identifiable, Sendable {
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
    let shared_goal: Bool?
    let archived_at: String?
    let group_progress: Double?
    let can_delete: Bool?
    let my_progress: Double?
    let my_progress_shared: Bool?
    let leaderboard: [WalkingChallengeMember]
}
private struct CommunityListResponse: Decodable { let communities: [WalkingCommunity] }
private struct ChallengeListResponse: Decodable { let challenges: [WalkingCommunityChallenge] }

@MainActor enum PausePathAPI {
    static func request(_ path: String, body: [String: Any]? = nil, retry: Bool = true, requiresAccount: Bool = false, query: [URLQueryItem] = []) async throws -> Data {
        let account = PausePathAccount.shared
        let user = account.userID
        let token = requiresAccount ? try await account.accessToken() : nil
        guard !requiresAccount || account.userID == user else { throw CancellationError() }
        guard var components = URLComponents(url: ServiceConfiguration.api.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ServiceFailure(status: 500, message: "The service request could not be prepared. Please try again.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw ServiceFailure(status: 500, message: "The service request could not be prepared. Please try again.")
        }
        var request = URLRequest(url: url)
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
            return try await self.request(path, body: body, retry: false, requiresAccount: requiresAccount, query: query)
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
    static func search(_ region: MKCoordinateRegion, onPage: ((SharedSearch) -> Void)? = nil) async throws -> SharedSearch {
        let area = try bounds(region)
        var body: [String: Any] = area
        var combined: SharedSearch?
        var seenCursors = Set<String>()
        while true {
            try Task.checkCancellation()
            let data = try await request("api/v1/pois/search", body: body)
            let page = try JSONDecoder().decode(SharedSearch.self, from: data)
            try Task.checkCancellation()
            if var accumulated = combined {
                let known = Set(accumulated.pois.map(\.id))
                accumulated.pois += page.pois.filter { !known.contains($0.id) }
                accumulated.next_cursor = page.next_cursor
                accumulated.truncated = page.truncated
                combined = accumulated
            } else {
                combined = page
            }
            onPage?(page)
            guard let cursor = page.next_cursor else {
                guard let combined else { throw ServiceFailure(status: 502, message: "Stop loading returned no results. Please refresh this area.") }
                return combined
            }
            guard seenCursors.insert(cursor).inserted else {
                throw ServiceFailure(status: 502, message: "Stop loading paused. Please refresh this area.")
            }
            body["cursor"] = cursor
        }
    }
    static func cafes(_ region: MKCoordinateRegion) async throws -> [DiscoveredPlace] {
        let b = try bounds(region)
        guard let west = b["west"], let south = b["south"],
              let east = b["east"], let north = b["north"] else {
            throw ServiceFailure(status: 500, message: "The map area could not be prepared. Please search again.")
        }
        let body: [String: Any] = ["category":"coffee", "limit": 25,
            "proximity": ["type":"Point", "coordinates":[region.center.longitude,region.center.latitude]],
            "bbox":[west, south, east, north]]
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
    static func createCommunity(name: String, username: String, requestID: UUID) async throws -> WalkingCommunity {
        let data = try await request("api/v1/communities", body: ["name": name, "display_name": username, "request_id": requestID.uuidString], requiresAccount: true)
        return try JSONDecoder().decode(WalkingCommunity.self, from: data)
    }
    static func joinCommunity(code: String, username: String, requestID: UUID) async throws -> WalkingCommunity {
        let data = try await request("api/v1/communities/join", body: ["invite_code": code, "display_name": username, "request_id": requestID.uuidString], requiresAccount: true)
        return try JSONDecoder().decode(WalkingCommunity.self, from: data)
    }
    static func updateCommunityUsername(_ username: String) async throws {
        _ = try await request("api/v1/communities/username", body: ["display_name": username], requiresAccount: true)
    }
    static func challenges(in community: UUID) async throws -> [WalkingCommunityChallenge] {
        let data = try await request("api/v1/communities/\(community.uuidString)/challenges", requiresAccount: true)
        return try JSONDecoder().decode(ChallengeListResponse.self, from: data).challenges
    }
    static func createChallenge(in community: UUID, name: String, metric: String, target: Double, shared: Bool = false, requestID: UUID) async throws {
        _ = try await request("api/v1/communities/\(community.uuidString)/challenges",
            body: ["name": name, "metric": metric, "target": target, "shared_goal": shared, "request_id": requestID.uuidString], requiresAccount: true)
    }
    static func updateChallengeProgress(_ challenge: UUID, amount: Double) async throws {
        _ = try await request("api/v1/challenges/\(challenge.uuidString)/progress", body: ["amount": amount], requiresAccount: true)
    }
    static func deleteChallengeProgress(_ challenge: UUID) async throws {
        _ = try await request("api/v1/challenges/\(challenge.uuidString)/progress/delete", body: [:], requiresAccount: true)
    }
    @discardableResult static func syncChallengeProgress(walks: [TrackedWalk], groups: [WalkingCommunity]? = nil, tasks: [UUID: [WalkingCommunityChallenge]]? = nil) async throws -> Set<UUID> {
        let owner = PausePathAccount.shared.userID
        guard let owner, UserDefaults.standard.string(forKey: "pausepath.shareProgressOwner") == owner,
              UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") else { return [] }
        let ownedWalks = walks.filter { $0.ownerID == owner }
        let loadedGroups: [WalkingCommunity]
        if let groups { loadedGroups = groups } else { loadedGroups = try await communities() }
        var changed = Set<UUID>()
        for group in loadedGroups {
            let list: [WalkingCommunityChallenge]
            if let tasks { guard let loaded = tasks[group.id] else { continue }; list = loaded }
            else { list = try await challenges(in: group.id) }
            for challenge in list where challenge.archived_at == nil {
                guard PausePathAccount.shared.userID == owner, UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") else { return changed }
                guard let start = challenge.startDate else { throw ServiceFailure(status: 422, message: "This challenge has an invalid start date. Progress has not been changed.") }
                let total = min(ChallengeProgressCalculator.total(metric: challenge.metric, walks: ownedWalks, from: start, until: Date()), 100000)
                if challenge.my_progress_shared == true && abs((challenge.my_progress ?? 0) - total) < 0.0001 { continue }
                try await updateChallengeProgress(challenge.id, amount: total)
                changed.insert(group.id)
                guard PausePathAccount.shared.userID == owner else { throw CancellationError() }
                if !UserDefaults.standard.bool(forKey: "pausepath.shareChallengeProgress") {
                    try await deleteChallengeProgress(challenge.id)
                    return changed
                }
            }
        }
        return changed
    }

    @discardableResult static func clearChallengeProgress(groups: [WalkingCommunity]? = nil, tasks: [UUID: [WalkingCommunityChallenge]]? = nil) async throws -> Set<UUID> {
        guard let owner = PausePathAccount.shared.userID else { return [] }
        let loadedGroups: [WalkingCommunity]
        if let groups { loadedGroups = groups } else { loadedGroups = try await communities() }
        var changed = Set<UUID>()
        for group in loadedGroups {
            let list: [WalkingCommunityChallenge]
            if let tasks { guard let loaded = tasks[group.id] else { continue }; list = loaded }
            else { list = try await challenges(in: group.id) }
            for challenge in list where challenge.my_progress_shared != false || (challenge.my_progress ?? 0) > 0 {
                guard PausePathAccount.shared.userID == owner else { throw CancellationError() }
                try await deleteChallengeProgress(challenge.id)
                changed.insert(group.id)
            }
        }
        return changed
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
