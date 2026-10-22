import HealthKit
import Observation
import CoreLocation

struct WalkingActivity: Identifiable {
    let id: String
    let date: Date
    let meters: Double?
    let seconds: Double
    let averageHeartRate: Double?
    let kind: String
    let symbol: String
    let steps: Double?
    let calories: Double?
    var pace: String { guard let meters, meters > 0 else { return "Unavailable" }; return String(format: "%.1f min/km", seconds / 60 / (meters / 1000)) }
}

struct BodyReading: Identifiable {
    let id: UUID
    let date: Date
    let value: Double
}
struct HealthDay: Identifiable {
    let date: Date
    let steps: Double?
    let calories: Double?
    var id: Date { date }
}

@MainActor @Observable final class HealthActivityStore {
    var activities: [WalkingActivity] = []
    var walkingSpeed: Double?
    var days: [HealthDay] = []
    var weight: [BodyReading] = []
    var bodyFat: [BodyReading] = []
    var height: [BodyReading] = []
    var status = "Connect Apple Health for recorded workouts, steps, active calories and body measurements."
    var isLoading = false
    var hasConnected = false
    private let store = HKHealthStore()
    private var workoutsByID: [String: HKWorkout] = [:]
    private var generation = UUID()
    private var lastRefresh: Date?
    func refreshIfConnected() async {
        guard UserDefaults.standard.bool(forKey: "pausepath.health.autoRefresh"), !isLoading,
              lastRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        await connect()
    }

    func connect() async {
        guard !isLoading else { return }
        guard HKHealthStore.isHealthDataAvailable() else { status = "Health data is unavailable on this device."; return }
        isLoading = true
        defer { isLoading = false }
        let request = generation
        let speed = HKQuantityType(.walkingSpeed)
        let heartRate = HKQuantityType(.heartRate)
        let steps = HKQuantityType(.stepCount)
        let energy = HKQuantityType(.activeEnergyBurned)
        do {
            try await store.requestAuthorization(toShare: [], read: [
                HKObjectType.workoutType(), HKSeriesType.workoutRoute(), speed, heartRate, steps, energy,
                HKQuantityType(.bodyMass), HKQuantityType(.bodyFatPercentage), HKQuantityType(.height)
            ])
            let since = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
            let dates = HKQuery.predicateForSamples(withStart: since, end: Date())
            let speeds = try await samples(type: speed, predicate: dates, limit: 1) as? [HKQuantitySample] ?? []
            let value = speeds.first?.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: .second()))
            let workouts = try await samples(type: .workoutType(), predicate: dates, limit: 500) as? [HKWorkout] ?? []
            let imported = workouts.map { workout in
                let presentation = Self.presentation(workout.workoutActivityType)
                return WalkingActivity(id: workout.uuid.uuidString, date: workout.startDate,
                    meters: workout.totalDistance?.doubleValue(for: .meter()), seconds: workout.duration,
                    averageHeartRate: workout.statistics(for: heartRate)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                    kind: presentation.0, symbol: presentation.1,
                    steps: workout.statistics(for: steps)?.sumQuantity()?.doubleValue(for: .count()),
                    calories: workout.statistics(for: energy)?.sumQuantity()?.doubleValue(for: .kilocalorie()))
            }
            let weights = try await readings(.bodyMass, unit: .gramUnit(with: .kilo), predicate: dates)
            let fat = try await readings(.bodyFatPercentage, unit: .percent(), predicate: dates)
            let heights = try await readings(.height, unit: .meterUnit(with: .centi), predicate: dates)
            let dayStart = Calendar.current.startOfDay(for: Date())
            let daySince = Calendar.current.date(byAdding: .day, value: -89, to: dayStart)!
            let stepDays = try await dailyTotals(steps, unit: .count(), since: daySince)
            let energyDays = try await dailyTotals(energy, unit: .kilocalorie(), since: daySince)
            guard request == generation else { return }
            walkingSpeed = value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            activities = imported
            workoutsByID = Dictionary(uniqueKeysWithValues: workouts.map { ($0.uuid.uuidString, $0) })
            weight = weights; bodyFat = fat; height = heights
            days = (0..<90).compactMap { offset in
                guard let date = Calendar.current.date(byAdding: .day, value: offset, to: daySince) else { return nil }
                return HealthDay(date: date, steps: stepDays[date], calories: energyDays[date])
            }
            hasConnected = true
            lastRefresh = Date()
            UserDefaults.standard.set(true, forKey: "pausepath.health.autoRefresh")
            status = "Up to 500 workouts and body readings from the last year; daily totals from the last 90 days. Missing values mean no data was shared or recorded."
        } catch {
            guard request == generation else { return }
            status = "Could not refresh Health. Previously loaded readings remain visible. Try again when ready."
        }
    }

    func route(for id: String) async throws -> [[CLLocationCoordinate2D]] {
        guard let workout = workoutsByID[id] else { return [] }
        let routes = try await samples(type: HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: workout), limit: HKObjectQueryNoLimit) as? [HKWorkoutRoute] ?? []
        var result: [[CLLocationCoordinate2D]] = []
        for route in routes {
            let locations: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
                var points: [CLLocation] = []
                store.execute(HKWorkoutRouteQuery(route: route) { _, batch, done, error in
                    if let error { continuation.resume(throwing: error); return }
                    points.append(contentsOf: batch ?? [])
                    if done { continuation.resume(returning: points) }
                })
            }
            result.append(locations.filter { $0.horizontalAccuracy >= 0 }.map(\.coordinate))
        }
        return result
    }

    func journeyMetrics(from start: Date, to end: Date) async throws -> (steps: Double?, calories: Double?, heartRate: Double?) {
        guard hasConnected, end > start else { return (nil, nil, nil) }
        let steps = try await intervalTotal(.stepCount, unit: .count(), start: start, end: end)
        let calories = try await intervalTotal(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end)
        let heartRate = try await intervalTotal(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()),
            start: start, end: end, average: true)
        return (steps, calories, heartRate)
    }
    private func intervalTotal(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date, average: Bool = false) async throws -> Double? {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: [.strictStartDate, .strictEndDate]),
                options: average ? .discreteAverage : .cumulativeSum) { _, statistics, error in
                    if let error { continuation.resume(throwing: error); return }
                    let quantity = average ? statistics?.averageQuantity() : statistics?.sumQuantity()
                    continuation.resume(returning: quantity?.doubleValue(for: unit))
                }
            store.execute(query)
        }
    }

    private func readings(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit, predicate: NSPredicate) async throws -> [BodyReading] {
        let data = try await samples(type: HKQuantityType(identifier), predicate: predicate, limit: 500) as? [HKQuantitySample] ?? []
        return data.map { BodyReading(id: $0.uuid, date: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
    }
    private func dailyTotals(_ type: HKQuantityType, unit: HKUnit, since: Date) async throws -> [Date: Double] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(quantityType: type,
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: since, end: Date()),
                options: .cumulativeSum, anchorDate: since, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error { continuation.resume(throwing: error); return }
                var values: [Date: Double] = [:]
                collection?.enumerateStatistics(from: since, to: Date()) { statistic, _ in
                    if let value = statistic.sumQuantity()?.doubleValue(for: unit) { values[statistic.startDate] = value }
                }
                continuation.resume(returning: values)
            }
            store.execute(query)
        }
    }
    private func samples(type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            })
        }
    }
    private static func presentation(_ type: HKWorkoutActivityType) -> (String, String) {
        switch type {
        case .walking: ("Walking", "figure.walk")
        case .running: ("Running", "figure.run")
        case .cycling: ("Cycling", "figure.outdoor.cycle")
        case .hiking: ("Hiking", "figure.hiking")
        case .swimming: ("Swimming", "figure.pool.swim")
        case .yoga: ("Yoga", "figure.yoga")
        case .traditionalStrengthTraining, .functionalStrengthTraining: ("Strength", "dumbbell.fill")
        case .elliptical: ("Elliptical", "figure.elliptical")
        case .rowing: ("Rowing", "figure.rower")
        case .dance, .cardioDance, .socialDance: ("Dance", "figure.dance")
        case .highIntensityIntervalTraining: ("HIIT", "figure.highintensity.intervaltraining")
        case .pilates: ("Pilates", "figure.pilates")
        case .mindAndBody: ("Mind & body", "figure.mind.and.body")
        default: ("Other workout", "figure.mixed.cardio")
        }
    }
    func clear() {
        UserDefaults.standard.set(false, forKey: "pausepath.health.autoRefresh")
        lastRefresh = nil
        generation = UUID()
        activities = []; walkingSpeed = nil; days = []; weight = []; bodyFat = []; height = []
        workoutsByID = [:]; hasConnected = false
        status = "Health session cleared. Manage permissions in iOS Settings."
    }
}
