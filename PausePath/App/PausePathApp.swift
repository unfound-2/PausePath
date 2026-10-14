import SwiftUI

@main struct PausePathApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

extension FacilityKind {
    var symbol: String {
        switch self { case .bench: "chair.fill"; case .bathroom: "figure.stand"; case .fountain: "drop.fill"; case .cafe: "cup.and.saucer.fill" }
    }
}
