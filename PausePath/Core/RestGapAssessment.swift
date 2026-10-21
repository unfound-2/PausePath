import Foundation

public struct BenchBoundary: Sendable {
    public let meters: Double
    public let open: Bool?
    public let publicAccess: Bool?
    public init(meters: Double, open: Bool?, publicAccess: Bool?) { self.meters = meters; self.open = open; self.publicAccess = publicAccess }
}
public struct RestGapAssessment: Sendable {
    public enum Status: String, Sendable { case meets, unverified, exceeds, unknown }
    public let longestGap: Double?
    public let status: Status
    public let uncertainStops: Int
    public static func assess(distance: Double, limit: Double, benches: [BenchBoundary], allowUnknown: Bool = true) -> Self {
        guard distance.isFinite, distance >= 0, limit.isFinite, limit > 0,
              benches.allSatisfy({ $0.meters.isFinite && $0.meters >= 0 && $0.meters <= distance }) else {
            return Self(longestGap: nil, status: .unknown, uncertainStops: 0)
        }
        let usable = benches.filter { $0.open != false && $0.publicAccess != false && (allowUnknown || ($0.open == true && $0.publicAccess == true)) }.sorted { $0.meters < $1.meters }
        let markers = [0] + usable.map(\.meters) + [distance]
        let gap = zip(markers, markers.dropFirst()).map { $1 - $0 }.max() ?? distance
        let uncertain = usable.filter { $0.open == nil || $0.publicAccess == nil }.count
        return Self(longestGap: gap, status: gap > limit + 0.5 ? .exceeds : uncertain > 0 ? .unverified : .meets, uncertainStops: uncertain)
    }
}
