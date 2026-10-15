import CoreLocation
import MapKit
import Observation
import AVFoundation
import UIKit

@MainActor @Observable final class WalkingNavigator: NSObject, @preconcurrency CLLocationManagerDelegate {
    enum State { case ready, locating, walking, paused, arrived }
    var state: State = .ready
    var location: CLLocation?
    var plan: GeneratedWalk?
    var progress = WalkProgress(paths: [])
    var status = "Start navigation when you are at the starting point."
    var isRecalculating = false
    var voiceEnabled = false
    private let manager = CLLocationManager()
    private let speech = AVSpeechSynthesizer()
    private var lastSpoken = ""
    private var wantsNavigation = false
    private var wantsPosition = false
    private var routeTask: Task<Void, Never>?
    private var token = UUID()
    override init() {
        super.init(); manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
    }
    func prepare(_ plan: GeneratedWalk) {
        stop(); self.plan = plan; returnOrigin = plan.start; progress = WalkProgress(paths: plan.paths)
        state = .ready; status = "Go to the start marker, then start navigation."
    }
    func locate() { wantsNavigation = false; wantsPosition = true; requestLocation() }
    func start() {
        guard plan != nil else { return }
        wantsNavigation = true; state = .locating; requestLocation()
    }
    private func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            if wantsNavigation { manager.startUpdatingLocation(); status = "Waiting for an accurate GPS location…" }
            else { manager.requestLocation(); status = "Finding your location…" }
        default:
            state = plan == nil ? .ready : .paused
            status = "Location access is required for navigation. Enable it in Settings; you can still preview the route."
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
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
        let accepted = progress.update(position: Coordinate(fix.coordinate.latitude, fix.coordinate.longitude), accuracy: fix.horizontalAccuracy, age: Date().timeIntervalSince(fix.timestamp))
        guard accepted else { status = "GPS is weak or outdated. Waiting for an accurate location…"; return }
        state = .walking; UIApplication.shared.isIdleTimerDisabled = true
        if progress.arrived {
            state = .arrived; wantsNavigation = false; manager.stopUpdatingLocation()
            UIApplication.shared.isIdleTimerDisabled = false; status = "You’ve arrived. Your walk is complete."
        } else if progress.offRoute {
            status = progress.hasStarted ? "You appear to be off route. Return to the path or recalculate the remaining walk." : "Go to the start marker, or recalculate from your location."
        } else { status = "Following your walking route." }
        speakIfNeeded()
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { status = "GPS is unavailable. Progress is paused until a fresh location arrives." }
    func pause() {
        token = UUID(); routeTask?.cancel(); isRecalculating = false
        wantsNavigation = false; wantsPosition = false; manager.stopUpdatingLocation(); speech.stopSpeaking(at: .immediate)
        UIApplication.shared.isIdleTimerDisabled = false
        if state != .arrived { state = .paused; status = "Walk paused. Resume when ready. Guidance works while PausePath is open." }
    }
    func stop() { pause(); state = .ready }
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
        return location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 35 && abs(now.timeIntervalSince(location.timestamp)) <= 15
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
