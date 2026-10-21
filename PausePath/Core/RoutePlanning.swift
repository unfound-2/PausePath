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
    public init(id: UUID = UUID(), date: Date = .now, routeName: String, distanceMeters: Double,
                activeSeconds: Double, completed: Bool, routeIdentity: String? = nil,
                steps: Int? = nil, startedAt: Date? = nil, journeySegments: [[Coordinate]]? = nil) {
        self.id = id; self.date = date; self.routeName = routeName
        self.distanceMeters = max(0, distanceMeters); self.activeSeconds = max(0, activeSeconds)
        self.completed = completed; self.routeIdentity = routeIdentity
        self.steps = steps
        self.startedAt = startedAt; self.journeySegments = journeySegments
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
    public var facilitiesAvailable: Bool
    public var note: String
    public var activityID: String?
    public init(routeName: String, manageability: Manageability, facilitiesAvailable: Bool, note: String, activityID: String?) {
        self.routeName = routeName; self.manageability = manageability; self.facilitiesAvailable = facilitiesAvailable
        self.note = note; self.activityID = activityID
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
