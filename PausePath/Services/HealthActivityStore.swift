import HealthKit
import Observation

struct WalkingActivity: Identifiable {
    let id: String
    let date: Date
    let meters: Double
    let seconds: Double
    let averageHeartRate: Double?
    var pace: String { meters > 0 ? String(format: "%.1f min/km", seconds / 60 / (meters / 1000)) : "Pace unavailable" }
}

@MainActor @Observable final class HealthActivityStore {
    var activities: [WalkingActivity] = []
    var walkingSpeed: Double?
    var status = "Health access is optional. Your route planner works without it."
    var isLoading = false
    private let store = HKHealthStore()

    func connect() async {
        guard HKHealthStore.isHealthDataAvailable() else { status = "Health data is unavailable on this device."; return }
        isLoading = true
        defer { isLoading = false }
        let speed = HKQuantityType(.walkingSpeed)
        let heartRate = HKQuantityType(.heartRate)
        do {
            try await store.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), speed, heartRate])
            let since = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            let dates = HKQuery.predicateForSamples(withStart: since, end: Date())
            let speeds = try await samples(type: speed, predicate: dates, limit: 1) as? [HKQuantitySample] ?? []
            let value = speeds.first?.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: .second()))
            walkingSpeed = value.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [dates, HKQuery.predicateForWorkouts(with: .walking)])
            let workouts = try await samples(type: .workoutType(), predicate: predicate, limit: 30) as? [HKWorkout] ?? []
            activities = workouts.map { workout in
                WalkingActivity(id: workout.uuid.uuidString, date: workout.startDate, meters: workout.totalDistance?.doubleValue(for: .meter()) ?? 0, seconds: workout.duration, averageHeartRate: workout.statistics(for: heartRate)?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())))
            }
            status = activities.isEmpty ? "No walking activities available in the last 30 days. Data may be absent or access may not be shared." : "Showing up to 30 walking activities from the last 30 days."
        } catch { status = "Could not read Health data. You can keep using manual estimates." }
    }

    private func samples(type: HKSampleType, predicate: NSPredicate, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            store.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            })
        }
    }
    func clear() { activities = []; walkingSpeed = nil; status = "Session data cleared. Manage Health permissions in Settings." }
}
