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

public struct WalkReflection: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var routeName: String
    public var feeling: Manageability
    public var distanceMeters: Double
    public var activeSeconds: Double
    public var completed: Bool
    public var note: String?

    public init(id: UUID = UUID(), date: Date = .now, routeName: String, feeling: Manageability,
                distanceMeters: Double, activeSeconds: Double, completed: Bool, note: String? = nil) {
        self.id = id
        self.date = date
        self.routeName = routeName
        self.feeling = feeling
        self.distanceMeters = max(0, distanceMeters)
        self.activeSeconds = max(0, activeSeconds)
        self.completed = completed
        self.note = note
    }
}

public struct TrackedWalk: Identifiable, Codable, Sendable {
    public var id: UUID
    public var date: Date
    public var routeName: String
    public var distanceMeters: Double
    public var activeSeconds: Double
    public var completed: Bool
    public var routeIdentity: String?
    public init(id: UUID = UUID(), date: Date = .now, routeName: String, distanceMeters: Double,
                activeSeconds: Double, completed: Bool, routeIdentity: String? = nil) {
        self.id = id; self.date = date; self.routeName = routeName
        self.distanceMeters = max(0, distanceMeters); self.activeSeconds = max(0, activeSeconds)
        self.completed = completed; self.routeIdentity = routeIdentity
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
