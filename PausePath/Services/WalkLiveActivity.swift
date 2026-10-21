import ActivityKit
import UIKit

@MainActor final class ActiveWalkSession {
    static let shared = ActiveWalkSession()
    weak var navigator: WalkingNavigator?
}

@MainActor final class WalkLiveActivity {
    private var activity: Activity<WalkActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastState: WalkActivityAttributes.ContentState?
    private var updates: Task<Void, Never>?
    func start(sessionID: UUID, name: String, state: WalkActivityAttributes.ContentState) -> String? {
        if activity != nil { update(state, force: true); return nil }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return "Live Activities are disabled in iOS Settings. Navigation still works." }
        guard UIApplication.shared.applicationState == .active else { return "Open PausePath to start its Live Activity." }
        do {
            activity = try Activity.request(attributes: WalkActivityAttributes(sessionID: sessionID, routeName: String(name.prefix(80))), content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(90)), pushType: nil)
            lastState = state; lastUpdate = .now
            return nil
        } catch { return "The Live Activity could not start. Navigation still works in the app." }
    }
    func update(_ state: WalkActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        let changed = lastState?.instruction != state.instruction || lastState?.paused != state.paused || lastState?.locating != state.locating
        guard force || changed || Date().timeIntervalSince(lastUpdate) >= 10 else { return }
        lastState = state; lastUpdate = .now
        // Serialize updates so a late GPS update cannot overwrite a newer pause.
        let previous = updates
        updates = Task {
            await previous?.value
            await activity.update(ActivityContent(state: state, staleDate: state.paused ? nil : .now.addingTimeInterval(90)))
        }
    }
    func end(_ state: WalkActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        let previous = updates
        updates = Task { await previous?.value; await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate) }
    }
    static func endOrphanedActivities() async {
        for activity in Activity<WalkActivityAttributes>.activities {
            var state = activity.content.state; state.paused = true
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
    }
}
