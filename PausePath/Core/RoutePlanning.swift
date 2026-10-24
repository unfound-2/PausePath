import Foundation

public enum FacilityKind: String, CaseIterable, Codable, Sendable {
    case bench = "Benches", bathroom = "Bathrooms", fountain = "Drinking fountains", cafe = "Cafés"
}

public enum WalkingGoal: String, CaseIterable, Codable, Sendable {
    case freshAir = "Fresh air", consistency = "Build a routine", distance = "Explore farther"
}

public enum PersonalGoalProfile: String, CaseIterable, Codable, Sendable {
    case recovery = "Returning after an injury"
    case beginner = "Building a walking routine"
    case seniorFriendly = "Comfortable, accessible walks"
    case chronicPain = "Managing walks with chronic pain"
    case generalFitness = "General wellbeing and fitness"
    case eventTraining = "Training for an event or sport"

    public var explanation: String {
        switch self {
        case .recovery: "Start with shorter, flatter routes and nearby rest stops. Follow your care team’s guidance."
        case .beginner: "Keep route suggestions approachable while you find a pace and routine that suit you."
        case .seniorFriendly: "Prioritize shorter distances, flatter routes, and more frequent rest-stop options."
        case .chronicPain: "Keep route choices flexible, with shorter options and nearby places to pause."
        case .generalFitness: "Balance distance and route variety around the goals you set."
        case .eventTraining: "Explore longer routes and gentle terrain that can support your own training plan."
        }
    }

    public func applyRouteDefaults(to preferences: inout RoutePreferences) {
        switch self {
        case .recovery, .seniorFriendly:
            preferences.distanceMeters = 800
            preferences.terrain = .flat
            preferences.maximumRestGapMeters = 250
            preferences.facilities = [.bench, .bathroom]
        case .beginner:
            preferences.distanceMeters = 1200
            preferences.terrain = .flat
            preferences.maximumRestGapMeters = 350
            preferences.facilities = [.bench]
        case .chronicPain:
            preferences.distanceMeters = 800
            preferences.terrain = .flat
            preferences.maximumRestGapMeters = 250
            preferences.facilities = [.bench]
        case .generalFitness:
            preferences.distanceMeters = 1800
            preferences.terrain = .any
            preferences.maximumRestGapMeters = 500
            preferences.facilities = [.bench]
        case .eventTraining:
            preferences.distanceMeters = 3000
            preferences.terrain = .gentle
            preferences.maximumRestGapMeters = 600
            preferences.facilities = []
        }
    }

    public var prefersGentlerRoutes: Bool {
        self == .recovery || self == .beginner || self == .seniorFriendly || self == .chronicPain
    }
}

public struct PausePathProfile: Codable, Equatable, Sendable {
    public var username: String?
    public var goal: PersonalGoalProfile
    public var weeklyWalkTarget: Int
    public var weeklyMinutesTarget: Int
    public var dailyRecapNotifications: Bool

    public init(username: String? = nil, goal: PersonalGoalProfile = .generalFitness, weeklyWalkTarget: Int = 3, weeklyMinutesTarget: Int = 90, dailyRecapNotifications: Bool = false) {
        self.username = username
        self.goal = goal
        self.weeklyWalkTarget = weeklyWalkTarget
        self.weeklyMinutesTarget = weeklyMinutesTarget
        self.dailyRecapNotifications = dailyRecapNotifications
    }
}

public enum TerrainPreference: String, CaseIterable, Codable, Sendable {
    case flat = "Mostly flat", gentle = "Gentle slopes", any = "Any terrain"
    public var maximumGrade: Double {
        switch self { case .flat: 3; case .gentle: 6; case .any: .infinity }
    }
}

public struct RoutePreferences: Codable, Equatable, Sendable {
    public var goal: WalkingGoal = .freshAir
    public var distanceMeters: Double = 1200
    public var maximumRestGapMeters: Double = 400
    public var terrain: TerrainPreference = .flat
    public var facilities: Set<FacilityKind> = [.bench]
    public var departure: Date = Date()
    public var speedMetersPerSecond: Double = 1
    public init() {}
}

public struct Coordinate: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Absolute intervals supplied by a provider after resolving local timezone, holidays and overnight hours.
public struct OpeningWindow: Codable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

public struct RouteFacility: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: FacilityKind
    public var coordinate: Coordinate
    /// Along-route distance, including access detours; never straight-line proximity.
    public var metersFromStart: Double
    public var hasSeating: Bool
    /// nil means unknown, [] means no open intervals in the planning horizon.
    public var openingWindows: [OpeningWindow]?
    public init(id: String, name: String, kind: FacilityKind, coordinate: Coordinate, metersFromStart: Double, hasSeating: Bool, openingWindows: [OpeningWindow]?) {
        self.id = id; self.name = name; self.kind = kind; self.coordinate = coordinate
        self.metersFromStart = metersFromStart; self.hasSeating = hasSeating; self.openingWindows = openingWindows
    }
    public func isOpen(at date: Date) -> Bool? {
        openingWindows.map { $0.contains { $0.start <= date && date < $0.end } }
    }
}

public struct WalkingRoute: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var meters: Double
    public var maximumGradePercent: Double?
    public var coordinates: [Coordinate]
    public var facilities: [RouteFacility]
    public init(id: String, name: String, meters: Double, maximumGradePercent: Double?, coordinates: [Coordinate], facilities: [RouteFacility]) {
        self.id = id; self.name = name; self.meters = meters; self.maximumGradePercent = maximumGradePercent
        self.coordinates = coordinates; self.facilities = facilities
    }
}

public struct RouteAssessment: Sendable {
    public var reasons: [String]
    public var durationSeconds: Double
    public var maximumRestGapMeters: Double
    public var matches: Bool { reasons.isEmpty }
}

public enum RoutePlanner {
    public static func assess(_ route: WalkingRoute, preferences: RoutePreferences) -> RouteAssessment {
        let speed = preferences.speedMetersPerSecond.isFinite && preferences.speedMetersPerSecond > 0 ? preferences.speedMetersPerSecond : 1
        var reasons: [String] = []
        if abs(route.meters - preferences.distanceMeters) > preferences.distanceMeters * 0.25 {
            reasons.append("Outside your distance range (±25%).")
        }
        if preferences.terrain != .any {
            if let grade = route.maximumGradePercent {
                if grade > preferences.terrain.maximumGrade { reasons.append("Steeper than your terrain preference.") }
            } else { reasons.append("Slope data is unknown.") }
        }
        let usable = route.facilities.filter {
            $0.metersFromStart >= 0 && $0.metersFromStart <= route.meters &&
            $0.isOpen(at: preferences.departure.addingTimeInterval($0.metersFromStart / speed)) == true
        }
        for kind in preferences.facilities.sorted(by: { $0.rawValue < $1.rawValue }) {
            if !usable.contains(where: { $0.kind == kind }) {
                reasons.append("\(kind.rawValue): no confirmed open stop at estimated arrival.")
            }
        }
        // Start and finish are interval boundaries, not assumed seats. Check both end gaps.
        let seats = usable.filter(\.hasSeating).map(\.metersFromStart).sorted()
        let boundaries = [0.0] + seats + [route.meters]
        let gap = zip(boundaries, boundaries.dropFirst()).map { $1 - $0 }.max() ?? route.meters
        if gap > preferences.maximumRestGapMeters { reasons.append("Confirmed seating is too far apart.") }
        return RouteAssessment(reasons: reasons, durationSeconds: route.meters / speed, maximumRestGapMeters: gap)
    }
}

public enum Manageability: String, CaseIterable, Codable, Sendable {
    case comfortable = "Comfortable", aboutRight = "About right", difficult = "Too demanding"
}

public struct TrackedWalk: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var routeName: String
    public var distanceMeters: Double
    public var activeSeconds: Double
    public var completed: Bool
    public var routeIdentity: String?
    public var steps: Int?
    public var startedAt: Date?
    public var journeySegments: [[Coordinate]]?
    public var activityKind: String?
    public var ownerID: String?
    public init(id: UUID = UUID(), date: Date = .now, routeName: String, distanceMeters: Double,
                activeSeconds: Double, completed: Bool, routeIdentity: String? = nil,
                steps: Int? = nil, startedAt: Date? = nil, journeySegments: [[Coordinate]]? = nil,
                activityKind: String? = nil, ownerID: String? = nil) {
        self.id = id; self.date = date; self.routeName = routeName
        self.distanceMeters = max(0, distanceMeters); self.activeSeconds = max(0, activeSeconds)
        self.completed = completed; self.routeIdentity = routeIdentity
        self.steps = steps
        self.startedAt = startedAt; self.journeySegments = journeySegments
        self.activityKind = activityKind; self.ownerID = ownerID
    }
}

public enum RouteAdjustment: String, CaseIterable, Codable, Sendable {
    case longer = "Try a longer route", flatter = "Prefer flatter terrain", closerStops = "Bring rest stops closer"
    public func apply(to preferences: inout RoutePreferences) {
        switch self {
        case .longer: preferences.distanceMeters = min(5000, preferences.distanceMeters + 200)
        case .flatter: preferences.terrain = .flat
        case .closerStops: preferences.maximumRestGapMeters = max(100, preferences.maximumRestGapMeters - 100)
        }
    }
}

public struct WalkFeedback: Identifiable, Codable, Sendable {
    public var id = UUID()
    public var date = Date()
    public var routeName: String
    public var manageability: Manageability
    /// nil means the walker did not know or did not answer.
    public var facilitiesAvailable: Bool?
    public var note: String
    public var activityID: String?
    public init(routeName: String, manageability: Manageability, facilitiesAvailable: Bool?, note: String, activityID: String?) {
        self.routeName = routeName; self.manageability = manageability; self.facilitiesAvailable = facilitiesAvailable
        self.note = note; self.activityID = activityID
    }
}

/// A local planning timeline. Health records are read with permission and never uploaded
/// by this model. A matching PausePath recording wins so one walk counts only once.
public struct WalkingHistoryEntry: Identifiable, Sendable {
    public enum Source: Sendable { case pausePath, appleHealth, sample }
    public let id: String
    public let source: Source
    public let start: Date
    public let end: Date
    public let activeSeconds: Double
    public let distanceMeters: Double?
    public let completed: Bool
    public let feedback: WalkFeedback?
    public var minutes: Double { activeSeconds / 60 }
    public init(id: String, source: Source, start: Date, end: Date, distanceMeters: Double?, completed: Bool,
                activeSeconds: Double? = nil, feedback: WalkFeedback? = nil) {
        self.id = id; self.source = source; self.start = start; self.end = end
        self.activeSeconds = max(0, activeSeconds ?? end.timeIntervalSince(start))
        self.distanceMeters = distanceMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.completed = completed; self.feedback = feedback
    }
}

public struct HealthWalkingRecord: Sendable {
    public let id: String
    public let start: Date
    public let seconds: Double
    public let distanceMeters: Double?
    public init(id: String, start: Date, seconds: Double, distanceMeters: Double?) {
        self.id = id; self.start = start; self.seconds = seconds; self.distanceMeters = distanceMeters
    }
}

public enum WalkingHistoryBuilder {
    public static func combine(tracked: [TrackedWalk], health: [HealthWalkingRecord], feedback: [WalkFeedback] = []) -> [WalkingHistoryEntry] {
        let feedbackByID = Dictionary(feedback.compactMap { item in item.activityID.map { ($0, item) } }, uniquingKeysWith: { newer, _ in newer })
        let local = tracked.filter { ($0.activityKind ?? "Walking") == "Walking" && $0.activeSeconds.isFinite && $0.activeSeconds > 0 }.map { walk in
            let start = walk.startedAt ?? walk.date.addingTimeInterval(-walk.activeSeconds)
            return WalkingHistoryEntry(id: walk.id.uuidString, source: .pausePath, start: start, end: max(walk.date, start.addingTimeInterval(walk.activeSeconds)),
                                       distanceMeters: walk.distanceMeters, completed: walk.completed, activeSeconds: walk.activeSeconds,
                                       feedback: feedbackByID[walk.id.uuidString])
        }
        let external = health.filter { $0.seconds.isFinite && $0.seconds > 0 }.map { walk in
            WalkingHistoryEntry(id: walk.id, source: .appleHealth, start: walk.start, end: walk.start.addingTimeInterval(walk.seconds),
                                distanceMeters: walk.distanceMeters, completed: true)
        }
        var result = local
        for candidate in external where !local.contains(where: { overlaps($0, candidate) }) {
            result.append(candidate)
        }
        return result.sorted { $0.start > $1.start }
    }

    private static func overlaps(_ a: WalkingHistoryEntry, _ b: WalkingHistoryEntry) -> Bool {
        let shared = min(a.end, b.end).timeIntervalSince(max(a.start, b.start))
        let shorterWindow = min(a.end.timeIntervalSince(a.start), b.end.timeIntervalSince(b.start))
        guard shared > 0, shorterWindow > 0, shared / shorterWindow >= 0.7 else { return false }
        if let left = a.distanceMeters, let right = b.distanceMeters, max(left, right) > 100 {
            return abs(left - right) / max(left, right) <= 0.35
        }
        return true
    }

    /// Eight complete synthetic weeks, clearly separated from personal records.
    public static func sample(reference: Date = .now, calendar: Calendar = .current) -> [WalkingHistoryEntry] {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: reference)?.start ?? calendar.startOfDay(for: reference)
        return (0..<8).flatMap { week -> [WalkingHistoryEntry] in
            guard let start = calendar.date(byAdding: .weekOfYear, value: week - 8, to: thisWeek) else { return [] }
            return (0..<7).compactMap { day in
                guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
                let minutes = Double(12 + week)
                return WalkingHistoryEntry(id: "sample-\(week)-\(day)", source: .sample,
                    start: date.addingTimeInterval(12 * 3600), end: date.addingTimeInterval(12 * 3600 + minutes * 60),
                    distanceMeters: minutes * 70, completed: true)
            }
        }
    }
}

public struct WalkingTrendSummary: Sendable {
    public let weeklyAverageMinutes: [Double]
    public let fittedMinutes: [Double]
    public let slopeMinutesPerDayPerWeek: Double
    public let baselineAverage: Double
    public let recentAverage: Double
    public let percentChange: Double?
    public let totalMinutes: Double
    public let additionalMinutesOverBaseline: Double

    public static func calculate(weeklyAverageMinutes values: [Double]) -> Self? {
        guard values.count >= 2, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let n = Double(values.count)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n
        let denominator = (0..<values.count).reduce(0.0) { $0 + pow(Double($1) - xMean, 2) }
        let slope = zip(values.indices, values).reduce(0.0) { $0 + (Double($1.0) - xMean) * ($1.1 - yMean) } / denominator
        let fit = values.indices.map { yMean + slope * (Double($0) - xMean) }
        let half = values.count / 2
        let baseline = values.prefix(half).reduce(0, +) / Double(half)
        let recent = values.suffix(half).reduce(0, +) / Double(half)
        let total = values.reduce(0, +) * 7
        return Self(weeklyAverageMinutes: values, fittedMinutes: fit, slopeMinutesPerDayPerWeek: slope,
            baselineAverage: baseline, recentAverage: recent, percentChange: baseline > 0 ? (recent - baseline) / baseline * 100 : nil,
            totalMinutes: total, additionalMinutesOverBaseline: total - baseline * Double(values.count) * 7)
    }

    public static func calculate(history: [WalkingHistoryEntry], reference: Date = .now, calendar: Calendar = .current) -> Self? {
        guard !history.isEmpty, let thisWeek = calendar.dateInterval(of: .weekOfYear, for: reference)?.start else { return nil }
        var recordedWeeks = 0
        let values = (0..<8).map { week -> Double in
            guard let start = calendar.date(byAdding: .weekOfYear, value: week - 8, to: thisWeek),
                  let end = calendar.date(byAdding: .day, value: 7, to: start) else { return 0 }
            let relevant = history.filter { $0.start < end && $0.end > start }
            if !relevant.isEmpty { recordedWeeks += 1 }
            let seconds = relevant.reduce(0.0) { total, entry in
                let overlap = max(0, min(entry.end, end).timeIntervalSince(max(entry.start, start)))
                let duration = max(1, entry.end.timeIntervalSince(entry.start))
                return total + entry.activeSeconds * overlap / duration
            }
            return seconds / 60 / 7
        }
        guard recordedWeeks >= 2 else { return nil }
        return calculate(weeklyAverageMinutes: values)
    }
}

public struct RouteFeatureSnapshot: Sendable {
    public let id: String
    public let distanceMeters: Double
    public let estimatedSeconds: Double
    public let maximumGradePercent: Double?
    public let surface: String?
    public let crossings: String?
    public let longestRestGapMeters: Double?
    public let restStatus: RestGapAssessment.Status
    public let facilityKinds: Set<FacilityKind>
    public init(id: String, distanceMeters: Double, estimatedSeconds: Double, maximumGradePercent: Double? = nil,
                surface: String? = nil, crossings: String? = nil, longestRestGapMeters: Double? = nil,
                restStatus: RestGapAssessment.Status, facilityKinds: Set<FacilityKind>) {
        self.id = id; self.distanceMeters = distanceMeters; self.estimatedSeconds = estimatedSeconds
        self.maximumGradePercent = maximumGradePercent; self.surface = surface; self.crossings = crossings
        self.longestRestGapMeters = longestRestGapMeters; self.restStatus = restStatus; self.facilityKinds = facilityKinds
    }
}

public struct RouteSuggestion: Sendable {
    public let routeID: String
    public let score: Double
    public let confidence: Double
    public let provisional: Bool
    public let reason: String
    public let unknownDetails: [String]
}

public enum PersonalRouteRanker {
    public static func rank(_ routes: [RouteFeatureSnapshot], preferences: RoutePreferences, history: [WalkingHistoryEntry]) -> [RouteSuggestion] {
        let reference = history.filter { $0.completed && $0.feedback?.manageability != .difficult }
            .prefix(12).compactMap(\.distanceMeters).filter { $0 > 0 }.sorted()
        let target = reference.isEmpty ? preferences.distanceMeters : reference[reference.count / 2]
        return routes.compactMap { route -> RouteSuggestion? in
            guard route.distanceMeters.isFinite, route.distanceMeters > 0,
                  abs(route.distanceMeters - preferences.distanceMeters) <= preferences.distanceMeters * 0.25,
                  preferences.facilities.isSubset(of: route.facilityKinds), route.restStatus != .exceeds else { return nil }
            if preferences.terrain != .any, let grade = route.maximumGradePercent, grade > preferences.terrain.maximumGrade { return nil }
            var unknown: [String] = []
            if route.maximumGradePercent == nil { unknown.append("slope") }
            if route.surface == nil { unknown.append("surface") }
            if route.crossings == nil { unknown.append("crossings") }
            if route.restStatus != .meets { unknown.append("rest-stop reliability") }
            let provisional = (preferences.terrain != .any && route.maximumGradePercent == nil) || route.restStatus != .meets
            let distanceFit = max(0, 1 - abs(route.distanceMeters - target) / max(target, 1))
            let restFit = route.longestRestGapMeters.map { max(0, 1 - $0 / max(preferences.maximumRestGapMeters, 1)) } ?? 0
            let confidence = max(0.1, min(1, 0.25 + (reference.isEmpty ? 0 : min(0.25, Double(reference.count) * 0.04)) +
                (route.maximumGradePercent == nil ? 0 : 0.15) + (route.restStatus == .meets ? 0.2 : 0) +
                (route.surface == nil ? 0 : 0.075) + (route.crossings == nil ? 0 : 0.075)))
            let score = distanceFit * 0.7 + restFit * 0.2 + confidence * 0.1
            let distanceReason = reference.isEmpty ? "close to your chosen distance" : "close to distances in your completed walks"
            let reason = "Suggested because it is \(distanceReason)" + (route.restStatus == .meets ? " and fits your mapped rest gap." : ".")
            return RouteSuggestion(routeID: route.id, score: score, confidence: confidence, provisional: provisional,
                                   reason: reason, unknownDetails: unknown)
        }.sorted { left, right in
            if left.provisional != right.provisional { return !left.provisional }
            if left.score != right.score { return left.score > right.score }
            return left.routeID < right.routeID
        }
    }
}


/// Only completed activity inside the challenge window counts. Route identities
/// never leave the device; a route is new only if absent from earlier records.
public enum ChallengeProgressCalculator {
    public static func total(metric: String, walks: [TrackedWalk], from start: Date, until end: Date) -> Double {
        let completed = walks.filter { $0.completed && $0.date <= end }
        let eligible = completed.filter { $0.date >= start }
        switch metric {
        case "walks": return Double(eligible.count)
        case "distance_km": return eligible.reduce(0) { $0 + valid($1.distanceMeters) / 1000 }
        case "minutes": return eligible.reduce(0) { $0 + valid($1.activeSeconds) / 60 }
        case "new_routes":
            let previous = Set(completed.filter { $0.date < start }.compactMap(\.routeIdentity))
            return Double(Set(eligible.compactMap(\.routeIdentity)).subtracting(previous).count)
        default: return 0
        }
    }
    private static func valid(_ value: Double) -> Double { value.isFinite ? max(0, value) : 0 }
}

/// A refreshed deck cannot award the same suggestion twice in one week.
public struct ChallengeRewardLedger: Codable {
    public var week = ""
    public var awarded: Set<String> = []
    public init() {}
    public mutating func claim(_ key: String, week currentWeek: String) -> Bool {
        if week != currentWeek { week = currentWeek; awarded = [] }
        return awarded.insert(key).inserted
    }
}


/// Milestones use completed, locally recorded journeys. Health imports stay separate.
public struct PathMilestones {
    public let walks: [TrackedWalk]
    public init(walks: [TrackedWalk]) {
        self.walks = walks.filter { $0.completed && $0.distanceMeters.isFinite && $0.activeSeconds.isFinite &&
            $0.distanceMeters > 0 && $0.activeSeconds > 0 }.sorted { $0.date < $1.date }
    }
    public var distance: Double { walks.reduce(0) { $0 + $1.distanceMeters } }
    public var longest: Double { walks.map(\.distanceMeters).max() ?? 0 }
    public var longestTime: Double { walks.map(\.activeSeconds).max() ?? 0 }
    public var activeDays: Int { Set(walks.map { Calendar.current.startOfDay(for: $0.date) }).count }
    public var recordIDs: Set<UUID> {
        var best = 0.0
        var result = Set<UUID>()
        for walk in walks {
            if best > 0 && walk.distanceMeters > best { result.insert(walk.id) }
            best = max(best, walk.distanceMeters)
        }
        return result
    }
    public var badges: [PathBadge] {
        var result: [PathBadge] = []
        for (goal, name) in [(1, "First footprint"), (5, "Finding rhythm"), (10, "Path regular"), (25, "Trail keeper")] {
            result.append(PathBadge(id: "walks-\(goal)", name: name, symbol: "figure.walk", requirement: "Complete \(goal) PausePath journeys", value: Double(walks.count), target: Double(goal)))
        }
        for (goal, name) in [(1, "First kilometre"), (5, "Green explorer"), (10, "Winding way"), (25, "Beyond the bend"), (50, "Horizon seeker"), (100, "Path pioneer")] {
            result.append(PathBadge(id: "distance-\(goal)", name: name, symbol: "point.topleft.down.to.point.bottomright.curvepath", requirement: "Travel \(goal) km across completed journeys", value: distance / 1000, target: Double(goal)))
        }
        for (goal, name) in [(3, "Long way home"), (5, "Going the distance")] {
            result.append(PathBadge(id: "longest-\(goal)", name: name, symbol: "map.fill", requirement: "Complete a \(goal) km journey", value: longest / 1000, target: Double(goal)))
        }
        for (goal, name) in [(30, "Time to wander"), (60, "An hour outdoors")] {
            result.append(PathBadge(id: "minutes-\(goal)", name: name, symbol: "sun.max.fill", requirement: "Complete a journey with \(goal) active minutes", value: longestTime / 60, target: Double(goal)))
        }
        for (goal, name) in [(3, "Showing up"), (7, "Seven green days")] {
            result.append(PathBadge(id: "days-\(goal)", name: name, symbol: "leaf.fill", requirement: "Complete journeys on \(goal) different days", value: Double(activeDays), target: Double(goal)))
        }
        for (goal, name) in [(1, "A new personal best"), (5, "Your own trailblazer")] {
            result.append(PathBadge(id: "pr-\(goal)", name: name, symbol: "trophy.fill", requirement: "Beat your longest journey \(goal) time(s)", value: Double(recordIDs.count), target: Double(goal)))
        }
        return result
    }
}
public struct PathBadge: Identifiable {
    public let id: String
    public let name: String
    public let symbol: String
    public let requirement: String
    public let value: Double
    public let target: Double
    public var earned: Bool { value >= target }
    public var fraction: Double { min(1, max(0, value / target)) }
}

public enum PathTrend {
    /// Equal, completed calendar-day windows exclude today's partial day.
    public static func distance(walks: [TrackedWalk], days: Int, now: Date = .now, calendar: Calendar = .current) -> (current: Double, previous: Double) {
        guard days > 0,
              let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now)),
              let prior = calendar.date(byAdding: .day, value: -days, to: start) else { return (0, 0) }
        let end = calendar.startOfDay(for: now)
        let valid = walks.filter { $0.distanceMeters.isFinite && $0.distanceMeters >= 0 }
        return (valid.filter { $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.distanceMeters },
                valid.filter { $0.date >= prior && $0.date < start }.reduce(0) { $0 + $1.distanceMeters })
    }
}

/// Distances along actual route legs, with the start and finish as boundaries.
/// A café or bathroom is not assumed to provide seating.
public enum RoutePreviewMetrics {
    public static func maximumMappedBenchGap(legDistances: [Double], stopKinds: [FacilityKind]) -> Double? {
        guard legDistances.count == stopKinds.count + 1,
              legDistances.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        var gap = 0.0
        var longest = 0.0
        for (index, meters) in legDistances.enumerated() {
            gap += meters
            if index < stopKinds.count && stopKinds[index] == .bench {
                longest = max(longest, gap)
                gap = 0
            }
        }
        return max(longest, gap)
    }
}

/// Calendar-week goals use recorded activity only; no inferred Health values.
public enum PersonalGoalProgress {
    public static func total(metric: String, walks: [TrackedWalk], start: Date, end: Date, calendar: Calendar = .current) -> Double {
        let eligible = walks.filter { $0.date >= start && $0.date < end }
        switch metric {
        case "minutes": return eligible.reduce(0) { $0 + ($1.activeSeconds.isFinite ? max(0, $1.activeSeconds) / 60 : 0) }
        case "days": return Double(Set(eligible.map { calendar.startOfDay(for: $0.date) }).count)
        default: return eligible.reduce(0) { $0 + ($1.distanceMeters.isFinite ? max(0, $1.distanceMeters) / 1000 : 0) }
        }
    }
}


/// Order suggested waypoints from start to destination; try individual stops as
/// well as the combined plan so one unreachable facility cannot erase all choices.
public enum RouteStopOrdering {
    public static func plans(start: Coordinate, end: Coordinate, stops: [Coordinate]) -> [[Int]] {
        let scale = cos((start.latitude + end.latitude) * .pi / 360)
        let dx = (end.longitude - start.longitude) * scale
        let dy = end.latitude - start.latitude
        let length = dx * dx + dy * dy
        func projection(_ point: Coordinate) -> Double {
            guard length > 0 else { return 0 }
            return ((point.longitude - start.longitude) * scale * dx + (point.latitude - start.latitude) * dy) / length
        }
        let ordered = stops.indices.filter {
            WalkingGeometry.distance(start, stops[$0]) > 35 && WalkingGeometry.distance(end, stops[$0]) > 35
        }.sorted {
            let a = projection(stops[$0]), b = projection(stops[$1])
            return a == b ? $0 < $1 : a < b
        }
        guard !ordered.isEmpty else { return [[]] }
        var result: [[Int]] = [[], ordered]
        if ordered.count > 1 { result += ordered.prefix(3).map { [$0] } }
        return result
    }
}
