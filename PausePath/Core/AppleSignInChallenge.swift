import Foundation
import CryptoKit
import Security

/// A fresh challenge for one Apple authorization, consumed before exchanging tokens.
struct AppleSignInChallenge {
    let nonce: String
    let state: String
    let createdAt: Date
    var hashedNonce: String { SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined() }
    init(now: Date = .now) throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        nonce = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        state = UUID().uuidString
        createdAt = now
    }
    func accepts(state: String?, now: Date = .now) -> Bool {
        state == self.state && now >= createdAt && now.timeIntervalSince(createdAt) < 600
    }
}
