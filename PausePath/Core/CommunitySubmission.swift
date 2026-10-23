import Foundation

public enum CommunityInvite {
    /// Accept a code or the exact PausePath deep link; other websites are not invite sources.
    public static func normalizedCode(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var code = trimmed
        if trimmed.contains("://") {
            guard let link = trimmed.components(separatedBy: .whitespacesAndNewlines).first(where: { $0.hasPrefix("pausepath://") }),
                  let url = URLComponents(string: link), url.scheme == "pausepath", url.host == "community", url.path == "/join",
                  let value = url.queryItems?.first(where: { $0.name == "code" })?.value else { return "" }
            code = value
        }
        return code.components(separatedBy: .whitespacesAndNewlines).joined().replacingOccurrences(of: "-", with: "").uppercased()
    }
    public static func isValid(_ code: String) -> Bool {
        (4...12).contains(code.count) && code.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (48...57).contains($0.value) }
    }
}

/// An account-scoped draft keeps one request identity across uncertain network retries.
public struct CommunitySubmissionDraft: Codable, Equatable, Sendable {
    public private(set) var requestID = UUID()
    public private(set) var ownerID = "signed-out"
    public private(set) var joining = false
    public private(set) var name = ""
    public private(set) var code = ""
    public private(set) var username = ""
    public init() {}
    public mutating func prepare(ownerID: String, joining: Bool, name: String, code: String, username: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanCode = CommunityInvite.normalizedCode(code)
        if self.ownerID != ownerID || self.joining != joining || self.username != cleanUsername ||
            (joining ? self.code != cleanCode : self.name != cleanName) { requestID = UUID() }
        self.ownerID = ownerID; self.joining = joining; self.name = cleanName; self.code = cleanCode; self.username = cleanUsername
    }
}


public struct GoalSubmissionDraft: Codable, Equatable, Sendable {
    public private(set) var requestID = UUID()
    public private(set) var ownerID = ""
    public private(set) var scope = ""
    public private(set) var name = ""
    public private(set) var metric = "walks"
    public private(set) var target = 3.0
    public private(set) var shared = false
    public init() {}
    public mutating func prepare(ownerID: String, scope: String, name: String, metric: String, target: Double, shared: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.ownerID != ownerID || self.scope != scope || self.name != clean || self.metric != metric || self.target != target || self.shared != shared {
            requestID = UUID()
        }
        self.ownerID = ownerID; self.scope = scope; self.name = clean; self.metric = metric; self.target = target; self.shared = shared
    }
}

public enum CommunityGoalState: String, CaseIterable, Sendable {
    case active = "Active", completed = "Completed", archived = "Archived"
    public static func classify(archived: Bool, progress: Double, target: Double) -> Self {
        if archived { return .archived }
        return progress >= target ? .completed : .active
    }
}

public enum CommunityFreshness {
    public static func shouldRefresh(lastLoaded: Date?, now: Date = Date(), lifetime: TimeInterval = 60) -> Bool {
        guard let lastLoaded else { return true }
        let age = now.timeIntervalSince(lastLoaded)
        return age < 0 || age >= lifetime
    }
}
