import Foundation

public enum RouteDifficultyFactor: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case distance
    case duration
    case elevation
    case surface
    case stairs
    case restStops

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .distance: "Distance"
        case .duration: "Estimated duration"
        case .elevation: "Elevation"
        case .surface: "Surface"
        case .stairs: "Stairs"
        case .restStops: "Rest-stop availability"
        }
    }
}

public enum RouteDifficultyLevel: String, CaseIterable, Codable, Sendable, Comparable {
    case easy = "Easy"
    case moderate = "Moderate"
    case hard = "Hard"

    fileprivate var severity: Int {
        switch self {
        case .easy: 1
        case .moderate: 2
        case .hard: 3
        }
    }

    fileprivate static func level(for severity: Int) -> Self {
        switch severity {
        case ...1: .easy
        case 2: .moderate
        default: .hard
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.severity < rhs.severity }
}

public enum RouteDifficultyDataStatus: String, Codable, Sendable {
    case complete
    case incomplete
    case unavailable
}

public enum RouteSurface: String, Codable, Sendable {
    case paved
    case mixed
    case uneven

    fileprivate var planningLevel: RouteDifficultyLevel {
        switch self {
        case .paved: .easy
        case .mixed: .moderate
        case .uneven: .hard
        }
    }

    public var description: String {
        switch self {
        case .paved: "Paved"
        case .mixed: "Mixed or gravel"
        case .uneven: "Uneven or unpaved"
        }
    }
}

/// Route facts available to the difficulty calculator. A nil field stays unknown;
/// callers must not substitute estimates for terrain or amenity data they do not have.
public struct RouteDifficultyInput: Sendable {
    public var distanceMeters: Double?
    public var durationSeconds: Double?
    public var elevationGainMeters: Double?
    public var maximumGradePercent: Double?
    public var surface: RouteSurface?
    public var stairFlights: Int?
    public var maximumRestStopGapMeters: Double?
    public var incompleteFactors: Set<RouteDifficultyFactor>

    public init(
        distanceMeters: Double? = nil,
        durationSeconds: Double? = nil,
        elevationGainMeters: Double? = nil,
        maximumGradePercent: Double? = nil,
        surface: RouteSurface? = nil,
        stairFlights: Int? = nil,
        maximumRestStopGapMeters: Double? = nil,
        incompleteFactors: Set<RouteDifficultyFactor> = []
    ) {
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.elevationGainMeters = elevationGainMeters
        self.maximumGradePercent = maximumGradePercent
        self.surface = surface
        self.stairFlights = stairFlights
        self.maximumRestStopGapMeters = maximumRestStopGapMeters
        self.incompleteFactors = incompleteFactors
    }
}

/// The enabled factors are a local planning preference, not a fitness profile.
public struct RouteDifficultyPreferences: Equatable, Sendable {
    public static let storageKey = "pausepath.routeDifficulty.includedFactors"
    public static let defaultStorageValue = RouteDifficultyFactor.allCases.map(\.rawValue).sorted().joined(separator: ",")

    public var includedFactors: Set<RouteDifficultyFactor>

    public init(includedFactors: Set<RouteDifficultyFactor> = Set(RouteDifficultyFactor.allCases)) {
        self.includedFactors = includedFactors
    }

    public init(storageValue: String) {
        includedFactors = Set(storageValue.split(separator: ",").compactMap { RouteDifficultyFactor(rawValue: String($0)) })
    }

    public var storageValue: String { includedFactors.map(\.rawValue).sorted().joined(separator: ",") }
}

public struct RouteDifficultyFactorResult: Identifiable, Sendable {
    public let factor: RouteDifficultyFactor
    public let status: RouteDifficultyDataStatus
    public let isIncluded: Bool
    public let detail: String
    public let level: RouteDifficultyLevel?

    public var id: RouteDifficultyFactor { factor }
}

public struct RouteDifficultyAssessment: Sendable {
    public let rating: RouteDifficultyLevel?
    public let factors: [RouteDifficultyFactorResult]

    public var label: String { rating?.rawValue ?? "Rating unavailable" }
    public var hasSelectedMissingData: Bool {
        !factors.contains(where: \.isIncluded) || factors.contains {
            $0.isIncluded && ($0.status != .complete || $0.level == nil)
        }
    }
    public var hasIncompleteData: Bool { factors.contains { $0.status == .incomplete } }

    public var limitedInformationMessage: String? {
        guard hasSelectedMissingData else { return nil }
        if factors.allSatisfy({ !$0.isIncluded }) {
            return "Choose at least one factor in Plan to get a route rating."
        }
        if rating != nil {
            return "This rating uses the route details available. Some selected factors are missing or incomplete, so comparisons with routes that have different data coverage may be unreliable."
        }
        return "There isn’t enough verified route information to rate this route yet."
    }
}

/// Deterministic, UI-independent rating rules. Factors use broad planning bands;
/// known factors can produce a rating when other data is missing, and the most
/// demanding known factor sets a floor so an average cannot hide it.
public enum RouteDifficultyCalculator {
    public static func assess(
        _ input: RouteDifficultyInput,
        preferences: RouteDifficultyPreferences = RouteDifficultyPreferences()
    ) -> RouteDifficultyAssessment {
        let factors = RouteDifficultyFactor.allCases.map { factor in
            result(for: factor, input: input, included: preferences.includedFactors.contains(factor))
        }
        let selected = factors.filter(\.isIncluded)
        let selectedKnown = selected.compactMap(\.level)
        guard !selectedKnown.isEmpty else {
            return RouteDifficultyAssessment(rating: nil, factors: factors)
        }

        let averageSeverity = Double(selectedKnown.reduce(0) { $0 + $1.severity }) / Double(selectedKnown.count)
        let averageLevel: RouteDifficultyLevel = averageSeverity < 1.5 ? .easy : (averageSeverity < 2.5 ? .moderate : .hard)
        // Only factors the person kept in Plan may raise the rating.
        let mostDemandingKnown = selectedKnown.max() ?? .easy
        return RouteDifficultyAssessment(rating: max(averageLevel, mostDemandingKnown), factors: factors)
    }

    private static func result(
        for factor: RouteDifficultyFactor,
        input: RouteDifficultyInput,
        included: Bool
    ) -> RouteDifficultyFactorResult {
        let measured: (detail: String, level: RouteDifficultyLevel)?
        switch factor {
        case .distance:
            if let meters = input.distanceMeters, meters.isFinite, meters >= 0 {
                let level: RouteDifficultyLevel = meters <= 1_500 ? .easy : (meters <= 4_000 ? .moderate : .hard)
                let range = switch level {
                case .easy: "≤ 1.5 km"
                case .moderate: "1.5–4 km"
                case .hard: "> 4 km"
                }
                measured = (String(format: "%.1f km · %@ range", meters / 1_000, range), level)
            } else { measured = nil }
        case .duration:
            if let seconds = input.durationSeconds, seconds.isFinite, seconds >= 0 {
                let minutes = Int((seconds / 60).rounded())
                let level: RouteDifficultyLevel = minutes <= 30 ? .easy : (minutes <= 60 ? .moderate : .hard)
                let range = switch level {
                case .easy: "≤ 30 min"
                case .moderate: "31–60 min"
                case .hard: "> 60 min"
                }
                measured = ("\(minutes) min estimated · \(range)", level)
            } else { measured = nil }
        case .elevation:
            let gain = input.elevationGainMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let grade = input.maximumGradePercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            if gain != nil || grade != nil {
                var details: [String] = []
                var levels: [RouteDifficultyLevel] = []
                if let gain {
                    let level: RouteDifficultyLevel = gain <= 50 ? .easy : (gain <= 200 ? .moderate : .hard)
                    let range = switch level {
                    case .easy: "≤ 50 m ascent"
                    case .moderate: "51–200 m ascent"
                    case .hard: "> 200 m ascent"
                    }
                    details.append("\(Int(gain.rounded())) m ascent (\(range))")
                    levels.append(level)
                }
                if let grade {
                    let level: RouteDifficultyLevel = grade <= 3 ? .easy : (grade <= 6 ? .moderate : .hard)
                    let range = switch level {
                    case .easy: "≤ 3%"
                    case .moderate: "3–6%"
                    case .hard: "> 6%"
                    }
                    details.append(String(format: "max grade %.1f%% (%@)", grade, range))
                    levels.append(level)
                }
                let level = levels.max() ?? .easy
                measured = ("\(details.joined(separator: " · ")) · \(level.rawValue.lowercased()) planning range", level)
            } else { measured = nil }
        case .surface:
            if let surface = input.surface {
                measured = ("\(surface.description) · \(surface.planningLevel.rawValue.lowercased()) planning range", surface.planningLevel)
            } else { measured = nil }
        case .stairs:
            if let flights = input.stairFlights, flights >= 0 {
                let level: RouteDifficultyLevel = flights == 0 ? .easy : (flights <= 3 ? .moderate : .hard)
                let range = switch level {
                case .easy: "0 flights"
                case .moderate: "1–3 flights"
                case .hard: "> 3 flights"
                }
                measured = ("\(flights) stair flights · \(range)", level)
            } else { measured = nil }
        case .restStops:
            if let gap = input.maximumRestStopGapMeters, gap.isFinite, gap >= 0 {
                let level: RouteDifficultyLevel = gap <= 500 ? .easy : (gap <= 1_000 ? .moderate : .hard)
                let range = switch level {
                case .easy: "≤ 500 m gap"
                case .moderate: "501–1,000 m gap"
                case .hard: "> 1,000 m gap"
                }
                measured = ("Up to \(Int(gap.rounded())) m between confirmed rest stops · \(range)", level)
            } else { measured = nil }
        }

        let status: RouteDifficultyDataStatus
        if input.incompleteFactors.contains(factor) {
            status = .incomplete
        } else if measured != nil {
            status = .complete
        } else {
            status = .unavailable
        }
        let detail: String
        if let measured {
            detail = status == .incomplete ? "\(measured.detail) · coverage incomplete" : measured.detail
        } else {
            detail = status == .incomplete ? "Some route data is available, but coverage is incomplete." : "No verified data is available for this route."
        }
        return RouteDifficultyFactorResult(
            factor: factor,
            status: status,
            isIncluded: included,
            detail: detail,
            level: measured?.level
        )
    }
}
