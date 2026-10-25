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
    public var weeklyActiveEnergyTargetKcal: Int?
    public var dailyRecapNotifications: Bool

    public init(username: String? = nil, goal: PersonalGoalProfile = .generalFitness, weeklyWalkTarget: Int = 3, weeklyMinutesTarget: Int = 90, weeklyActiveEnergyTargetKcal: Int? = nil, dailyRecapNotifications: Bool = false) {
        self.username = username
        self.goal = goal
        self.weeklyWalkTarget = weeklyWalkTarget
        self.weeklyMinutesTarget = weeklyMinutesTarget
        self.weeklyActiveEnergyTargetKcal = weeklyActiveEnergyTargetKcal
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

/// Exponential activity-growth scenario used only for clearly labeled synthetic examples.
/// It is not an efficacy estimate and must not be fitted to pre-app data as an outcome.
public struct ActivityGrowthModel: Sendable {
    public let baselineMinutesPerDay: Double
    public let amplitudeMinutesPerDay: Double
    public let growthRatePerWeek: Double
    public let horizonWeeks: Double

    public init(baselineMinutesPerDay: Double, amplitudeMinutesPerDay: Double,
                growthRatePerWeek: Double, horizonWeeks: Double) {
        self.baselineMinutesPerDay = max(0, baselineMinutesPerDay.isFinite ? baselineMinutesPerDay : 0)
        self.amplitudeMinutesPerDay = max(0, amplitudeMinutesPerDay.isFinite ? amplitudeMinutesPerDay : 0)
        self.growthRatePerWeek = growthRatePerWeek.isFinite ? max(0.000_001, growthRatePerWeek) : 0.000_001
        self.horizonWeeks = horizonWeeks.isFinite ? max(0, horizonWeeks) : 0
    }

    /// One fictional example for onboarding and the separately labeled Insights demo.
    public static let illustrativeSample = ActivityGrowthModel(
        baselineMinutesPerDay: 12, amplitudeMinutesPerDay: 10,
        growthRatePerWeek: 0.25, horizonWeeks: 8
    )

    public func predictedMinutesPerDay(atWeek week: Double) -> Double {
        let t = max(0, week.isFinite ? week : 0)
        return baselineMinutesPerDay + amplitudeMinutesPerDay * (1 - exp(-growthRatePerWeek * t))
    }

    /// Integral mean of m(t) over weeks 0...T, in predicted minutes per day.
    public func averageMinutesPerDay(overWeeks weeks: Double? = nil) -> Double {
        let duration = max(0, (weeks ?? horizonWeeks).isFinite ? (weeks ?? horizonWeeks) : 0)
        guard duration > 0 else { return baselineMinutesPerDay }
        let kt = growthRatePerWeek * duration
        let response = kt < 1e-6 ? 0 : 1 - (-expm1(-kt) / kt)
        return baselineMinutesPerDay + amplitudeMinutesPerDay * response
    }

    public var endpointIncreasePercent: Double? {
        guard baselineMinutesPerDay > 0 else { return nil }
        return (predictedMinutesPerDay(atWeek: horizonWeeks) - baselineMinutesPerDay) / baselineMinutesPerDay * 100
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
                let minutes = ActivityGrowthModel.illustrativeSample.predictedMinutesPerDay(atWeek: Double(week))
                return WalkingHistoryEntry(id: "sample-\(week)-\(day)", source: .sample,
                    start: date.addingTimeInterval(12 * 3600), end: date.addingTimeInterval(12 * 3600 + minutes * 60),
                    distanceMeters: minutes * 70, completed: true)
            }
        }
    }
}

public enum WeeklyWalkingCoverage: String, Sendable {
    case observed, noRecordedSession, invalidRecords
}

/// A missing week is an unknown observation, never an observed zero.
public struct WeeklyWalkingObservation: Sendable {
    public let weekStart: Date
    public let weekEnd: Date
    public let minutesPerDay: Double?
    public let validForFit: Bool
    public let weight: Double
    public let coverage: WeeklyWalkingCoverage
    public let recordCount: Int
    public init(weekStart: Date, weekEnd: Date, minutesPerDay: Double?, validForFit: Bool,
                weight: Double, coverage: WeeklyWalkingCoverage, recordCount: Int) {
        self.weekStart = weekStart; self.weekEnd = weekEnd; self.minutesPerDay = minutesPerDay
        self.validForFit = validForFit; self.weight = weight; self.coverage = coverage; self.recordCount = recordCount
    }
}

public struct WalkingTrendPoint: Sendable {
    public let weekCoordinate: Double
    public let minutesPerDay: Double
}

public struct WalkingTrendSummary: Sendable {
    public enum Status: Sendable { case ready, insufficient, invalid }
    public enum LambdaMethod: Sendable { case generalizedCrossValidation, fixedSmallSample }
    public let status: Status
    public let observations: [WeeklyWalkingObservation]
    public let observedPoints: [WalkingTrendPoint]
    public let fittedPoints: [WalkingTrendPoint]
    public let curve: [WalkingTrendPoint]
    /// Spline derivative at each observed knot, in recorded minutes/day/week.
    public let derivativePoints: [WalkingTrendPoint]
    public let lambda: Double?
    public let lambdaMethod: LambdaMethod?
    public let weightedResidual: Double?
    public let limitation: String?
    /// Derivative at the latest observed week, in recorded minutes/day/week.
    public let slopeMinutesPerDayPerWeek: Double?
    public let baselineAverage: Double?
    public let recentAverage: Double?
    public let percentChange: Double?
    public let totalObservedMinutes: Double
    public let additionalMinutesOverBaseline: Double?

    private init(status: Status, observations: [WeeklyWalkingObservation], observedPoints: [WalkingTrendPoint],
                 fittedPoints: [WalkingTrendPoint] = [], curve: [WalkingTrendPoint] = [],
                 derivativePoints: [WalkingTrendPoint] = [], lambda: Double? = nil,
                 lambdaMethod: LambdaMethod? = nil, weightedResidual: Double? = nil, limitation: String? = nil,
                 slope: Double? = nil, baseline: Double? = nil, recent: Double? = nil,
                 percentChange: Double? = nil, total: Double = 0, additional: Double? = nil) {
        self.status = status; self.observations = observations; self.observedPoints = observedPoints
        self.fittedPoints = fittedPoints; self.curve = curve; self.derivativePoints = derivativePoints
        self.lambda = lambda; self.lambdaMethod = lambdaMethod
        self.weightedResidual = weightedResidual; self.limitation = limitation
        self.slopeMinutesPerDayPerWeek = slope; self.baselineAverage = baseline; self.recentAverage = recent
        self.percentChange = percentChange; self.totalObservedMinutes = total; self.additionalMinutesOverBaseline = additional
    }

    /// Eight complete, consecutive synthetic weeks; this path never reads personal records.
    public static func calculate(weeklyAverageMinutes values: [Double]) -> Self {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let anchor = Date(timeIntervalSince1970: 1_767_571_200) // 2026-01-05 UTC
        let observations = values.enumerated().compactMap { index, value -> WeeklyWalkingObservation? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: index, to: anchor),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            return WeeklyWalkingObservation(weekStart: start, weekEnd: end, minutesPerDay: value,
                                            validForFit: true, weight: 1, coverage: .observed, recordCount: 7)
        }
        return calculate(observations: observations, calendar: calendar)
    }

    public static func calculate(history: [WalkingHistoryEntry], reference: Date = .now, calendar: Calendar = .current) -> Self {
        if history.contains(where: { $0.source == .sample }) && history.contains(where: { $0.source != .sample }) {
            return Self(status: .invalid, observations: [], observedPoints: [],
                        limitation: "Sample and personal records cannot be combined.")
        }
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: reference)?.start else {
            return calculate(observations: [], calendar: calendar)
        }
        let observations = (0..<8).compactMap { week -> WeeklyWalkingObservation? in
            guard let start = calendar.date(byAdding: .weekOfYear, value: week - 8, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            // The caller supplies either personal history or the separate synthetic fixture.
            let relevant = history.filter { $0.start < end && $0.end > start }
            let valid = relevant.filter { $0.activeSeconds.isFinite && $0.activeSeconds > 0 && $0.end > $0.start }
            let seconds = valid.reduce(0.0) { total, entry in
                let overlap = max(0, min(entry.end, end).timeIntervalSince(max(entry.start, start)))
                return total + entry.activeSeconds * overlap / entry.end.timeIntervalSince(entry.start)
            }
            let days = calendar.dateComponents([.day], from: start, to: end).day ?? 7
            let hasValue = !valid.isEmpty && seconds.isFinite && seconds > 0 && days > 0
            return WeeklyWalkingObservation(weekStart: start, weekEnd: end,
                minutesPerDay: hasValue ? seconds / 60 / Double(days) : nil,
                validForFit: hasValue, weight: hasValue ? 1 : 0,
                coverage: hasValue ? .observed : relevant.isEmpty ? .noRecordedSession : .invalidRecords,
                recordCount: valid.count)
        }
        return calculate(observations: observations, calendar: calendar)
    }

    public static func calculate(observations: [WeeklyWalkingObservation], calendar: Calendar = .current) -> Self {
        guard !observations.isEmpty, observations.count <= 16,
              observations.allSatisfy({ $0.weekStart.timeIntervalSinceReferenceDate.isFinite &&
                  $0.weekEnd.timeIntervalSinceReferenceDate.isFinite && $0.weekStart < $0.weekEnd &&
                  calendar.dateComponents([.day], from: $0.weekStart, to: $0.weekEnd).day == 7 &&
                  $0.weight.isFinite && $0.weight >= 0 && $0.recordCount >= 0 &&
                  ($0.minutesPerDay == nil || ($0.minutesPerDay!.isFinite && $0.minutesPerDay! >= 0)) &&
                  (!$0.validForFit || ($0.coverage == .observed && $0.minutesPerDay != nil && $0.weight > 0 && $0.recordCount > 0)) }),
              zip(observations, observations.dropFirst()).allSatisfy({ $0.weekEnd <= $1.weekStart }) else {
            return Self(status: .invalid, observations: observations, observedPoints: [], limitation: "Invalid weekly records.")
        }
        let first = observations[0].weekStart
        let points = observations.compactMap { observation -> (WalkingTrendPoint, Double)? in
            guard observation.validForFit, observation.coverage == .observed,
                  let value = observation.minutesPerDay, observation.weight > 0,
                  observation.recordCount > 0 else { return nil }
            let days = calendar.dateComponents([.day], from: first, to: observation.weekStart).day ?? -1
            guard days >= 0 else { return nil }
            return (WalkingTrendPoint(weekCoordinate: Double(days) / 7, minutesPerDay: value), observation.weight)
        }
        let observed = points.map(\.0)
        let total = observations.compactMap { item -> Double? in
            guard item.validForFit, item.coverage == .observed, item.weight > 0,
                  item.recordCount > 0, let value = item.minutesPerDay else { return nil }
            let days = calendar.dateComponents([.day], from: item.weekStart, to: item.weekEnd).day ?? 0
            return value * Double(days)
        }.reduce(0, +)
        guard total.isFinite else {
            return Self(status: .invalid, observations: observations, observedPoints: observed,
                        limitation: "The recorded minutes are outside the supported range.")
        }
        // Fixed four-calendar-week windows: do not substitute earlier valid weeks for missing ones.
        let baseline = windowAverage(observations.prefix(4))
        let recent = observations.count == 8 ? windowAverage(observations.suffix(4)) : nil
        let comparisonReady = observations.count == 8 && observations.allSatisfy {
            $0.validForFit && $0.coverage == .observed && $0.weight > 0 && $0.recordCount > 0 && $0.minutesPerDay != nil
        }
        let additional = comparisonReady && baseline != nil ? total - baseline! * 56 : nil
        let change = baseline.flatMap { base in base > 0 ? recent.map { ($0 - base) / base * 100 } : nil }
        guard points.count >= 4 else {
            return Self(status: .insufficient, observations: observations, observedPoints: observed,
                        limitation: "At least four weeks with recorded sessions are needed.", baseline: baseline,
                        recent: recent, percentChange: change, total: total, additional: additional)
        }
        let x = observed.map(\.weekCoordinate), y = observed.map(\.minutesPerDay), w = points.map(\.1)
        guard zip(x, x.dropFirst()).allSatisfy({ $1 - $0 > 0.000001 }),
              let fit = CubicWalkingSpline.fit(x: x, y: y, weights: w) else {
            return Self(status: .invalid, observations: observations, observedPoints: observed,
                        limitation: "The recorded weeks could not be fitted.", baseline: baseline,
                        recent: recent, percentChange: change, total: total, additional: additional)
        }
        return Self(status: .ready, observations: observations, observedPoints: observed,
                    fittedPoints: zip(x, fit.fitted).map { WalkingTrendPoint(weekCoordinate: $0, minutesPerDay: $1) },
                    curve: fit.samples,
                    derivativePoints: zip(x, fit.derivatives).map { WalkingTrendPoint(weekCoordinate: $0, minutesPerDay: $1) },
                    lambda: fit.lambda, lambdaMethod: fit.method,
                    weightedResidual: fit.residual, limitation: fit.method == .fixedSmallSample
                        ? "Only four or five observed weeks; smoothing uses a fixed small-sample setting." : nil,
                    slope: fit.slopeAtLast, baseline: baseline, recent: recent,
                    percentChange: change, total: total, additional: additional)
    }

    private static func windowAverage<S: Sequence>(_ weeks: S) -> Double? where S.Element == WeeklyWalkingObservation {
        let values = Array(weeks)
        guard values.count == 4, values.allSatisfy({ $0.validForFit && $0.coverage == .observed &&
            $0.weight > 0 && $0.recordCount > 0 && $0.minutesPerDay != nil }) else { return nil }
        return values.compactMap(\.minutesPerDay).reduce(0, +) / 4
    }
}

/// Reinsch's natural cubic smoothing spline. For knots x and fitted knot values f,
/// integral (f'')² = fᵀ Q R⁻¹ Qᵀ f. Solve (R + λ Qᵀ W⁻¹ Q)u = Qᵀy, then
/// f = y − λ W⁻¹Qu. Dense pivoted elimination is bounded to 16 weeks here.
/// GCV tries 21 fixed log-spaced λ values and computes tr(I−S) from A⁻¹B;
/// complexity is O(21 n⁴) with these tiny bounded matrices.
private enum CubicWalkingSpline {
    struct Fit {
        let fitted: [Double]
        let samples: [WalkingTrendPoint]
        let derivatives: [Double]
        let slopeAtLast: Double
        let lambda: Double
        let method: WalkingTrendSummary.LambdaMethod
        let residual: Double
    }
    static func fit(x: [Double], y: [Double], weights w: [Double]) -> Fit? {
        let n = x.count, m = n - 2
        guard n >= 4, n <= 16, y.count == n, w.count == n,
              x.allSatisfy(\.isFinite), y.allSatisfy(\.isFinite),
              w.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(x, x.dropFirst()).allSatisfy({ $1 - $0 > 0.000001 }) else { return nil }
        let h = zip(x, x.dropFirst()).map { $1 - $0 }
        var q = Array(repeating: Array(repeating: 0.0, count: m), count: n)
        var r = Array(repeating: Array(repeating: 0.0, count: m), count: m)
        for j in 0..<m {
            q[j][j] = 1 / h[j]
            q[j + 1][j] = -1 / h[j] - 1 / h[j + 1]
            q[j + 2][j] = 1 / h[j + 1]
            r[j][j] = (h[j] + h[j + 1]) / 3
            if j + 1 < m { r[j][j + 1] = h[j + 1] / 6; r[j + 1][j] = h[j + 1] / 6 }
        }
        let b = (0..<m).map { i in (0..<m).map { j in (0..<n).reduce(0.0) { $0 + q[$1][i] * q[$1][j] / w[$1] } } }
        let qty = (0..<m).map { j in (0..<n).reduce(0.0) { $0 + q[$1][j] * y[$1] } }
        let candidates: [Double] = n < 6 ? [1] : (-8...12).map { pow(10, Double($0) / 2) }
        var winner: (lambda: Double, fitted: [Double], residual: Double, gcv: Double)?
        for lambda in candidates {
            let a = (0..<m).map { i in (0..<m).map { j in r[i][j] + lambda * b[i][j] } }
            guard let u = solve(a, qty) else { continue }
            let fitted = (0..<n).map { i in y[i] - lambda / w[i] * (0..<m).reduce(0.0) { $0 + q[i][$1] * u[$1] } }
            let residual = (0..<n).reduce(0.0) { $0 + w[$1] * pow(y[$1] - fitted[$1], 2) }
            guard fitted.allSatisfy(\.isFinite), residual.isFinite else { continue }
            var trace = 0.0
            if n >= 6 {
                for column in 0..<m {
                    let rhs = (0..<m).map { b[$0][column] }
                    guard let solved = solve(a, rhs) else { trace = .nan; break }
                    trace += solved[column]
                }
            }
            let denominator = lambda * trace
            let gcv = n < 6 ? residual : (denominator > 1e-10 ? Double(n) * residual / (denominator * denominator) : .infinity)
            guard gcv.isFinite else { continue }
            if winner == nil || gcv < winner!.gcv - 1e-12 { winner = (lambda, fitted, residual, gcv) }
        }
        guard let best = winner else { return nil }
        // Natural cubic interpolation through the smoothed knots gives a C² curve.
        var second = Array(repeating: 0.0, count: n)
        if m > 0 {
            let system = (0..<m).map { i in (0..<m).map { j -> Double in
                if i == j { return 2 * (h[i] + h[i + 1]) }
                if abs(i - j) == 1 { return h[max(i, j)] }
                return 0
            } }
            let rhs: [Double] = (0..<m).map { i -> Double in
                let nextSlope = (best.fitted[i + 2] - best.fitted[i + 1]) / h[i + 1]
                let previousSlope = (best.fitted[i + 1] - best.fitted[i]) / h[i]
                return 6.0 * (nextSlope - previousSlope)
            }
            guard let interior = solve(system, rhs) else { return nil }
            for i in 0..<m { second[i + 1] = interior[i] }
        }
        var samples: [WalkingTrendPoint] = []
        var derivatives: [Double] = []
        var lastSlope = 0.0
        for i in 0..<(n - 1) {
            let width = h[i]
            let linear = (best.fitted[i + 1] - best.fitted[i]) / width - width * (2 * second[i] + second[i + 1]) / 6
            let cubic = (second[i + 1] - second[i]) / (6 * width)
            derivatives.append(linear)
            for part in 0..<8 {
                let dx = width * Double(part) / 8
                let value = best.fitted[i] + linear * dx + second[i] * dx * dx / 2 + cubic * dx * dx * dx
                samples.append(WalkingTrendPoint(weekCoordinate: x[i] + dx, minutesPerDay: value))
            }
            if i == n - 2 { lastSlope = linear + second[i] * width + 3 * cubic * width * width }
        }
        derivatives.append(lastSlope)
        samples.append(WalkingTrendPoint(weekCoordinate: x[n - 1], minutesPerDay: best.fitted[n - 1]))
        guard derivatives.allSatisfy(\.isFinite), samples.allSatisfy({ $0.minutesPerDay.isFinite }) else { return nil }
        return Fit(fitted: best.fitted, samples: samples, derivatives: derivatives, slopeAtLast: lastSlope,
                   lambda: best.lambda, method: n < 6 ? .fixedSmallSample : .generalizedCrossValidation,
                   residual: best.residual)
    }
    private static func solve(_ matrix: [[Double]], _ rhs: [Double]) -> [Double]? {
        let n = rhs.count
        guard matrix.count == n, matrix.allSatisfy({ $0.count == n }), rhs.allSatisfy(\.isFinite) else { return nil }
        var a = matrix, b = rhs
        for col in 0..<n {
            guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }),
                  abs(a[pivot][col]) > 1e-12, a[pivot][col].isFinite else { return nil }
            a.swapAt(col, pivot); b.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = a[row][col] / a[col][col]
                for j in col..<n { a[row][j] -= factor * a[col][j] }
                b[row] -= factor * b[col]
            }
        }
        var solution = Array(repeating: 0.0, count: n)
        for row in (0..<n).reversed() {
            let tail = (row + 1..<n).reduce(0.0) { $0 + a[row][$1] * solution[$1] }
            solution[row] = (b[row] - tail) / a[row][row]
            guard solution[row].isFinite else { return nil }
        }
        return solution
    }
}

public struct RouteFeatureSnapshot: Sendable {
    public let id: String
    public let distanceMeters: Double
    public let estimatedSeconds: Double
    public let maximumGradePercent: Double?
    public let surface: String?
    public let crossings: String?
    public let crossingCount: Int?
    public let confirmedRestPoints: Int?
    /// nil is unknown; false means a required stop is known unavailable.
    public let requiredFacilitiesAvailable: Bool?
    public let longestRestGapMeters: Double?
    public let restStatus: RestGapAssessment.Status
    public let facilityKinds: Set<FacilityKind>
    public init(id: String, distanceMeters: Double, estimatedSeconds: Double, maximumGradePercent: Double? = nil,
                surface: String? = nil, crossings: String? = nil, crossingCount: Int? = nil,
                confirmedRestPoints: Int? = nil, requiredFacilitiesAvailable: Bool? = nil,
                longestRestGapMeters: Double? = nil, restStatus: RestGapAssessment.Status,
                facilityKinds: Set<FacilityKind>) {
        self.id = id; self.distanceMeters = distanceMeters; self.estimatedSeconds = estimatedSeconds
        self.maximumGradePercent = maximumGradePercent; self.surface = surface; self.crossings = crossings
        self.crossingCount = crossingCount; self.confirmedRestPoints = confirmedRestPoints
        self.requiredFacilitiesAvailable = requiredFacilitiesAvailable
        self.longestRestGapMeters = longestRestGapMeters; self.restStatus = restStatus; self.facilityKinds = facilityKinds
    }
}

public struct RouteCostWeights: Sendable {
    public let distance: Double, grade: Double, crossings: Double, restPoints: Double, uncertainty: Double
    public static let standard = RouteCostWeights(distance: 0.35, grade: 0.15, crossings: 0.10,
                                                   restPoints: 0.15, uncertainty: 0.25)
    public init(distance: Double, grade: Double, crossings: Double, restPoints: Double, uncertainty: Double) {
        self.distance = distance; self.grade = grade; self.crossings = crossings
        self.restPoints = restPoints; self.uncertainty = uncertainty
    }
    public var isValid: Bool {
        let values = [distance, grade, crossings, restPoints, uncertainty]
        return values.allSatisfy { $0.isFinite && $0 >= 0 } && abs(values.reduce(0, +) - 1) <= 0.000001
    }
}

public struct RouteCostComponents: Sendable {
    public let distance: Double, grade: Double, crossings: Double, restPoints: Double, uncertainty: Double
    public var total: Double { distance + grade + crossings + restPoints + uncertainty }
}

public struct RouteSuggestion: Sendable {
    public let routeID: String
    /// Lower is better; this is a planning cost, not a safety score.
    public let score: Double
    public let dataCompleteness: Double
    public let provisional: Bool
    public let reason: String
    public let unknownDetails: [String]
    public let components: RouteCostComponents
    public let eligibility: String
}

public struct RouteExclusion: Sendable {
    public let routeID: String
    public let reasons: [String]
}

public struct RouteRankingResult: Sendable {
    public let suggestions: [RouteSuggestion]
    public let excluded: [RouteExclusion]
    public let targetDistanceMeters: Double
    public let invalidWeights: Bool
}

public enum PersonalRouteRanker {
    public static func rank(_ routes: [RouteFeatureSnapshot], preferences: RoutePreferences, history: [WalkingHistoryEntry]) -> [RouteSuggestion] {
        evaluate(routes, preferences: preferences, history: history).suggestions
    }

    /// Hard constraints are checked before cost. Missing features receive their worst normalized
    /// term as well as an uncertainty penalty; provisional routes follow fully known feasible ones.
    public static func evaluate(_ routes: [RouteFeatureSnapshot], preferences: RoutePreferences,
                                history: [WalkingHistoryEntry], weights: RouteCostWeights = .standard) -> RouteRankingResult {
        let personalRecordsPresent = history.contains { $0.source != .sample }
        let selectedHistory = personalRecordsPresent ? history.filter { $0.source != .sample } : history
        let recent = selectedHistory.filter { $0.completed && $0.feedback?.manageability != .difficult &&
            $0.distanceMeters != nil && $0.distanceMeters!.isFinite && $0.distanceMeters! > 0 }
            .sorted { $0.end > $1.end }.prefix(12).compactMap(\.distanceMeters).sorted()
        let target = recent.count >= 3 ? recent[recent.count / 2] : preferences.distanceMeters
        guard weights.isValid, preferences.distanceMeters.isFinite, preferences.distanceMeters > 0,
              preferences.maximumRestGapMeters.isFinite, preferences.maximumRestGapMeters > 0,
              target.isFinite, target > 0 else {
            return RouteRankingResult(suggestions: [], excluded: routes.map {
                RouteExclusion(routeID: $0.id, reasons: ["Invalid ranking preferences or weights."])
            }, targetDistanceMeters: preferences.distanceMeters, invalidWeights: !weights.isValid)
        }
        var suggestions: [RouteSuggestion] = []
        var excluded: [RouteExclusion] = []
        for route in routes {
            var reasons: [String] = []
            if !route.distanceMeters.isFinite || route.distanceMeters <= 0 ||
                abs(route.distanceMeters - preferences.distanceMeters) > preferences.distanceMeters * 0.25 {
                reasons.append("Outside your chosen distance range (±25%).")
            }
            if !preferences.facilities.isSubset(of: route.facilityKinds) { reasons.append("Missing a required stop category.") }
            if route.requiredFacilitiesAvailable == false { reasons.append("A required stop is unavailable.") }
            if let grade = route.maximumGradePercent {
                if !grade.isFinite || grade < 0 { reasons.append("Invalid slope data.") }
                else if preferences.terrain != .any && grade > preferences.terrain.maximumGrade {
                    reasons.append("Steeper than your terrain limit.")
                }
            }
            if let count = route.crossingCount, count < 0 { reasons.append("Invalid crossing data.") }
            if let count = route.confirmedRestPoints, count < 0 { reasons.append("Invalid rest-stop data.") }
            if route.restStatus == .exceeds || (route.longestRestGapMeters.map { $0.isFinite && $0 > preferences.maximumRestGapMeters + 0.5 } ?? false) {
                reasons.append("Rest stops are farther apart than your limit.")
            }
            if route.restStatus == .unknown || route.longestRestGapMeters.map({ !$0.isFinite || $0 < 0 }) == true {
                reasons.append("Rest-gap data is unusable.")
            }
            if !reasons.isEmpty { excluded.append(RouteExclusion(routeID: route.id, reasons: reasons)); continue }
            var unknown: [String] = []
            if route.maximumGradePercent == nil { unknown.append("slope") }
            if route.surface?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false { unknown.append("surface") }
            if route.crossingCount == nil { unknown.append("crossings") }
            if !preferences.facilities.isEmpty && route.requiredFacilitiesAvailable == nil { unknown.append("required-stop availability") }
            if route.restStatus != .meets || route.confirmedRestPoints == nil { unknown.append("rest-stop reliability") }
            // Five equally weighted data fields, not a probability of safety.
            let uncertainty = Double(unknown.count) / 5
            let gradeScale = preferences.terrain == .any ? 6.0 : preferences.terrain.maximumGrade
            let gradeRatio = route.maximumGradePercent.map { $0 / gradeScale } ?? 1
            let crossingRatio = route.crossingCount.map { min(Double($0) / 4, 1) } ?? 1
            let restRatio = route.confirmedRestPoints.map { 1 - min(Double($0) / 3, 1) } ?? 1
            let components = RouteCostComponents(
                distance: weights.distance * pow((route.distanceMeters - target) / target, 2),
                grade: weights.grade * pow(gradeRatio, 2),
                crossings: weights.crossings * crossingRatio,
                restPoints: weights.restPoints * restRatio,
                uncertainty: weights.uncertainty * uncertainty)
            guard components.total.isFinite else {
                excluded.append(RouteExclusion(routeID: route.id, reasons: ["Route cost could not be calculated."]))
                continue
            }
            let distanceReason = recent.count >= 3 ? "close to distances in your completed walks" : "close to your chosen distance"
            let restReason = route.restStatus == .meets && (route.confirmedRestPoints ?? 0) > 0
                ? " with confirmed rest stops" : ""
            suggestions.append(RouteSuggestion(routeID: route.id, score: components.total,
                dataCompleteness: 1 - uncertainty, provisional: !unknown.isEmpty,
                reason: "Suggested because it is \(distanceReason)\(restReason).",
                unknownDetails: unknown, components: components,
                eligibility: "Within your distance range, includes required stop categories, and does not exceed a known terrain or rest-gap limit."))
        }
        suggestions.sort {
            if $0.provisional != $1.provisional { return !$0.provisional }
            if abs($0.score - $1.score) > 1e-12 { return $0.score < $1.score }
            return $0.routeID < $1.routeID
        }
        excluded.sort { $0.routeID < $1.routeID }
        return RouteRankingResult(suggestions: suggestions, excluded: excluded,
                                  targetDistanceMeters: target, invalidWeights: false)
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
        case "single_distance_km": return eligible.map { valid($0.distanceMeters) / 1000 }.max() ?? 0
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
        for (goal, name, symbol) in [
            (1, "First footprint", "shoeprints.fill"),
            (5, "Finding rhythm", "figure.walk"),
            (10, "Path regular", "figure.hiking"),
            (25, "Trail keeper", "mountain.2.fill")
        ] {
            result.append(PathBadge(id: "walks-\(goal)", name: name, symbol: symbol, requirement: "Complete \(goal) PausePath journeys", value: Double(walks.count), target: Double(goal)))
        }
        for (goal, name, symbol) in [
            (1, "First kilometre", "point.topleft.down.to.point.bottomright.curvepath"),
            (5, "Green explorer", "location.north.circle.fill"),
            (10, "Winding way", "map.fill"),
            (25, "Beyond the bend", "signpost.right.fill"),
            (50, "Horizon seeker", "sun.horizon.fill"),
            (100, "Path pioneer", "globe.americas.fill")
        ] {
            result.append(PathBadge(id: "distance-\(goal)", name: name, symbol: symbol, requirement: "Travel \(goal) km across completed journeys", value: distance / 1000, target: Double(goal)))
        }
        for (goal, name, symbol) in [(3, "Long way home", "map.fill"), (5, "Going the distance", "mountain.2.fill")] {
            result.append(PathBadge(id: "longest-\(goal)", name: name, symbol: symbol, requirement: "Complete a \(goal) km journey", value: longest / 1000, target: Double(goal)))
        }
        for (goal, name, symbol) in [(30, "Time to wander", "clock.fill"), (60, "An hour outdoors", "sun.max.fill")] {
            result.append(PathBadge(id: "minutes-\(goal)", name: name, symbol: symbol, requirement: "Complete a journey with \(goal) active minutes", value: longestTime / 60, target: Double(goal)))
        }
        for (goal, name, symbol) in [(3, "Showing up", "calendar"), (7, "Seven green days", "calendar.badge.checkmark")] {
            result.append(PathBadge(id: "days-\(goal)", name: name, symbol: symbol, requirement: "Complete journeys on \(goal) different days", value: Double(activeDays), target: Double(goal)))
        }
        for (goal, name, symbol) in [(1, "A new personal best", "trophy.fill"), (5, "Your own trailblazer", "rosette")] {
            result.append(PathBadge(id: "pr-\(goal)", name: name, symbol: symbol, requirement: "Beat your longest journey \(goal) time(s)", value: Double(recordIDs.count), target: Double(goal)))
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
