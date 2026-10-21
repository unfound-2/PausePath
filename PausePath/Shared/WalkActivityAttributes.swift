import ActivityKit
import Foundation

struct WalkActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var instruction: String
        var remainingMeters: Int
        var nextPause: String?
        var nextPauseMeters: Int?
        var paused: Bool
        var locating: Bool
        var arrived: Bool
        var updatedAt: Date
    }
    let sessionID: UUID
    let routeName: String
}
