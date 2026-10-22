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
