import CoreLocation
import CoreMotion
import MapKit
import Observation
import AVFoundation
import UIKit

@MainActor @Observable final class WalkingNavigator: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State { case ready, locating, walking, paused, arrived }
    var state: State = .ready
    var location: CLLocation?
    private(set) var displayCoordinate: Coordinate?
    var plan: GeneratedWalk?
    var progress = WalkProgress(paths: [])
    var status = "Start navigation when you are at the starting point."
    var isRecalculating = false
    var voiceEnabled = false
    private(set) var journeySegments: [[Coordinate]] = []
    private(set) var journeyStartedAt: Date?
    private var beginsJourneySegment = true
    private let pedometer = CMPedometer()
    private var pedometerRunning = false
    private var previousSteps = 0
    private var intervalSteps: Int?
    private var pedometerToken = UUID()
    var recordedSteps: Int? { intervalSteps.map { previousSteps + $0 } }
    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var lastSpoken = ""
    private var wantsNavigation = false
    private var wantsPosition = false
    private var requestedPreciseAccuracy = false
    private var recentGPSCoordinates: [(Coordinate, Date)] = []
    private var accumulatedActiveSeconds: TimeInterval = 0
    private var activeIntervalStartedAt: Date?
    private var routeTask: Task<Void, Never>?
    private var token = UUID()
    override init() {
        super.init(); manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
        manager.allowsBackgroundLocationUpdates = false
    }
    func prepare(_ plan: GeneratedWalk) {
        stop(); self.plan = plan; returnOrigin = plan.start; progress = WalkProgress(paths: plan.paths)
        accumulatedActiveSeconds = 0; activeIntervalStartedAt = nil
        recentGPSCoordinates = []
        journeySegments = []; journeyStartedAt = nil; beginsJourneySegment = true
        previousSteps = 0; intervalSteps = nil
        state = .ready; status = "Go to the start marker, then start navigation."
    }
    func locate() { wantsNavigation = false; wantsPosition = true; requestLocation() }
    func start() {
        guard plan != nil else { return }
        wantsNavigation = true; state = .locating
        requestLocation()
    }
    private func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if wantsNavigation, manager.accuracyAuthorization == .reducedAccuracy, !requestedPreciseAccuracy {
                requestedPreciseAccuracy = true
                manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "ActiveWalk")
            }
            if wantsNavigation {
                manager.allowsBackgroundLocationUpdates = false
                manager.startUpdatingLocation()
                status = manager.accuracyAuthorization == .fullAccuracy
                    ? "Waiting for an accurate GPS location…"
                    : "GPS is approximate. Enable Precise Location for reliable route progress."
            }
            else { manager.requestLocation(); status = "Finding your location…" }
        default:
            state = plan == nil ? .ready : .paused
            status = "Location access is required for navigation. Enable it in Settings; you can still preview the route."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.accuracyAuthorization == .fullAccuracy { requestedPreciseAccuracy = false }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if manager.accuracyAuthorization == .reducedAccuracy {
                status = "Location is approximate. Turn on Precise Location for live route progress."
            }
            if wantsNavigation || wantsPosition { requestLocation() }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            pause(); status = "Location access is unavailable. Enable it in Settings to navigate."
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        location = fix
        guard wantsNavigation, state == .walking || state == .locating, !isRecalculating else {
            if wantsPosition {
                wantsPosition = false
                status = freshLocation() ? "Location found." : "Location is approximate. Enable Precise Location or search a starting address."
            }; return
        }
        let rawCoordinate = Coordinate(fix.coordinate.latitude, fix.coordinate.longitude)
        let fixAge = Date().timeIntervalSince(fix.timestamp)
        guard rawCoordinate.latitude.isFinite, rawCoordinate.longitude.isFinite,
              (-90...90).contains(rawCoordinate.latitude), (-180...180).contains(rawCoordinate.longitude),
              fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 50,
              fixAge.isFinite, fixAge >= -2, fixAge <= 15 else {
            beginsJourneySegment = true
            status = "GPS is weak or outdated. Waiting for an accurate location…"; return
        }
        if journeyStartedAt == nil { journeyStartedAt = fix.timestamp }
        startStepCounting(at: fix.timestamp)
        if beginsJourneySegment {
            journeySegments.append([rawCoordinate]); beginsJourneySegment = false
        } else {
            journeySegments[journeySegments.count - 1].append(rawCoordinate)
        }
        let filteredCoordinate = smooth(rawCoordinate, at: fix.timestamp)
        let accepted = progress.update(position: filteredCoordinate, accuracy: fix.horizontalAccuracy, age: fixAge)
        guard accepted else { status = "GPS is weak or outdated. Waiting for an accurate location…"; return }
        displayCoordinate = filteredCoordinate
        state = .walking
        if activeIntervalStartedAt == nil { activeIntervalStartedAt = fix.timestamp }
        UIApplication.shared.isIdleTimerDisabled = true
        if progress.arrived {
            finishActiveInterval(at: fix.timestamp)
            stopStepCounting()
            state = .arrived; wantsNavigation = false; manager.stopUpdatingLocation()
            UIApplication.shared.isIdleTimerDisabled = false; status = "You’ve arrived. Your walk is complete."
        } else if progress.offRoute {
            status = progress.hasStarted ? "You appear to be off route. Return to the path or recalculate the remaining walk." : "Go to the start marker, or recalculate from your location."
        } else { status = "Following your walking route." }
        speakIfNeeded()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "GPS is unavailable. Progress is paused until a fresh location arrives." }
    func pause() {
        stopStepCounting()
        token = UUID(); routeTask?.cancel(); isRecalculating = false
        finishActiveInterval(at: .now)
        wantsNavigation = false; wantsPosition = false; manager.stopUpdatingLocation(); speech.stopSpeaking(at: .immediate)
        recentGPSCoordinates = []
        beginsJourneySegment = true
        UIApplication.shared.isIdleTimerDisabled = false
        if state != .arrived { state = .paused; status = "Walk paused. Resume when ready. Location tracking stops while paused." }
    }
    private func startStepCounting(at date: Date) {
        guard !pedometerRunning, CMPedometer.isStepCountingAvailable() else { return }
        pedometerRunning = true
        let token = UUID(); pedometerToken = token
        pedometer.startUpdates(from: date) { [weak self] data, error in
            let count = data?.numberOfSteps.intValue
            Task { @MainActor [weak self] in
                guard let self, self.pedometerToken == token else { return }
                if error == nil, let count { self.intervalSteps = count }
            }
        }
    }
    private func stopStepCounting() {
        guard pedometerRunning else { return }
        pedometer.stopUpdates(); pedometerRunning = false; pedometerToken = UUID()
        if let intervalSteps { previousSteps += intervalSteps; self.intervalSteps = 0 }
    }
    func stop() { pause(); state = .ready }
    var elapsedActiveSeconds: TimeInterval {
        accumulatedActiveSeconds + (activeIntervalStartedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0)
    }
    private func finishActiveInterval(at date: Date) {
        if let activeIntervalStartedAt {
            accumulatedActiveSeconds += max(0, date.timeIntervalSince(activeIntervalStartedAt))
            self.activeIntervalStartedAt = nil
        }
    }
    var remainingMeters: Double {
        guard let plan, progress.totalMeters > 0 else { return 0 }
        return max(0, plan.distance * (1 - progress.completedMeters / progress.totalMeters))
    }
    var currentInstruction: String {
        if state == .arrived { return "You’ve arrived" }
        guard let plan, plan.legs.indices.contains(progress.legIndex) else { return "Ready to walk" }
        if !progress.hasStarted { return "Go to the starting point" }
        if progress.offRoute { return "Return to the route or recalculate" }
        return stepDetails?.instruction ?? "Continue to the end of this leg"
    }
    var stepDetails: (instruction: String, meters: Double)? {
        guard let plan, plan.legs.indices.contains(progress.legIndex) else { return nil }
        let leg = plan.legs[progress.legIndex]
        let length = WalkingGeometry.length(progress.paths[progress.legIndex])
        let along = length > 0 ? progress.metersAlongLeg / length * leg.distance : 0
        var end = 0.0
        for step in leg.steps {
            end += step.distance
            if end > along + 5, !step.instructions.isEmpty {
                return (step.instructions, max(0, end - along))
            }
        }
        return nil
    }
    func freshLocation(at now: Date = Date()) -> Bool {
        guard let location else { return false }
        return location.horizontalAccuracy.isFinite && location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 50 &&
            location.coordinate.latitude.isFinite && location.coordinate.longitude.isFinite &&
            (-90...90).contains(location.coordinate.latitude) && (-180...180).contains(location.coordinate.longitude) &&
            now.timeIntervalSince(location.timestamp) >= -2 && now.timeIntervalSince(location.timestamp) <= 15
    }

    private func smooth(_ coordinate: Coordinate, at timestamp: Date) -> Coordinate {
        recentGPSCoordinates.removeAll { timestamp.timeIntervalSince($0.1) > 10 }
        recentGPSCoordinates.append((coordinate, timestamp))
        if recentGPSCoordinates.count > 3 { recentGPSCoordinates.removeFirst(recentGPSCoordinates.count - 3) }
        let count = Double(recentGPSCoordinates.count)
        return Coordinate(recentGPSCoordinates.reduce(0) { $0 + $1.0.latitude } / count,
                          recentGPSCoordinates.reduce(0) { $0 + $1.0.longitude } / count)
    }
    func speakIfNeeded() {
        guard voiceEnabled, state == .walking || state == .arrived else { return }
        let instruction = currentInstruction
        guard instruction != lastSpoken else { return }
        lastSpoken = instruction
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: instruction))
    }
    func setVoice(_ enabled: Bool) {
        voiceEnabled = enabled; lastSpoken = ""
        if enabled { speakIfNeeded() } else { speech.stopSpeaking(at: .immediate) }
    }
    /// Explicit rerouting preserves all remaining waypoints. Return now intentionally
    /// replaces them with the original start; neither operation claims verified amenities.
    func recalculate(returnToStart: Bool) {
        guard let plan, let location, freshLocation() else { status = "A fresh, accurate GPS location is needed to recalculate."; return }
        token = UUID(); let current = token; routeTask?.cancel(); isRecalculating = true
        speech.stopSpeaking(at: .immediate)
        let originalStart = returnOrigin ?? plan.start
        let endpoints: [Coordinate] = returnToStart ? [originalStart] : plan.paths.dropFirst(progress.legIndex).compactMap(\.last)
        let origin = Coordinate(location.coordinate.latitude, location.coordinate.longitude)
        if endpoints.count == 1, let end = endpoints.first, WalkingGeometry.distance(origin, end) <= 25 {
            isRecalculating = false; status = "You are already near this destination. End the walk when ready."; return
        }
        routeTask = Task {
            defer { if current == token { isRecalculating = false } }
            do {
                var legs: [MKRoute] = []; var start = origin
                for end in endpoints {
                    let leg = try await WalkingDirections.route(from: start, to: end, departure: Date())
                    guard let first = leg.polyline.walkingCoordinates.first, let last = leg.polyline.walkingCoordinates.last,
                          WalkingGeometry.distance(start, first) <= 30, WalkingGeometry.distance(end, last) <= 30 else {
                        throw NSError(domain: "PausePath", code: 2)
                    }
                    legs.append(leg); start = last
                }
                guard current == token else { return }
                let revised = GeneratedWalk(name: returnToStart ? "Return to start" : "Recalculated walk", legs: legs, preferences: plan.preferences)
                self.plan = revised; progress = WalkProgress(paths: revised.paths)
                // Preserve the original origin for subsequent return-to-start actions.
                returnOrigin = returnOrigin ?? originalStart
                lastSpoken = ""; status = "Route updated. Distance has changed; terrain and rest stops remain unverified."
            } catch { if current == token { status = "Could not recalculate. Your previous route is still shown. Try again when connected." } }
        }
    }
    private var returnOrigin: Coordinate?
    func returnToStart() { recalculate(returnToStart: true) }
}
