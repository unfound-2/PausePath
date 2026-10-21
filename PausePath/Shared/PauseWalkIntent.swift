import AppIntents

/// LiveActivityIntent runs in the containing app's process, including while locked.
struct PauseWalkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Pause walk"
    static var description = IntentDescription("Pause the currently active PausePath walk and stop its location updates.")
    static var openAppWhenRun = false
    @Parameter(title: "Walk session") var sessionID: String
    init() {}
    init(sessionID: String) { self.sessionID = sessionID }
    func perform() async throws -> some IntentResult {
        #if !PAUSEPATH_WIDGET
        await MainActor.run { if let navigator = ActiveWalkSession.shared.navigator, navigator.sessionID.uuidString == sessionID { navigator.pause() } }
        #endif
        return .result()
    }
}
