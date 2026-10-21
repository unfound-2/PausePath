import SwiftUI

struct SavedAreasSettingsView: View {
    @State private var revision = UUID()
    @AppStorage("pausepath.walk.background") private var backgroundWalks = true
    @AppStorage("pausepath.walk.liveActivity") private var liveActivities = true
    var body: some View {
        Form {
            Section("Saved stop information") {
                LabeledContent("Areas", value: "\(PersistentAreaCache.count)")
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: Int64(PersistentAreaCache.bytes), countStyle: .file))
                Text("Up to eight recently explored areas are kept on this phone for seven days, within a 5 MB limit. Public stop information is saved; temporary Mapbox business results are not. Saved information can be outdated. Streets, maps and new walking directions still need a connection.").font(.caption).foregroundStyle(.secondary)
                Button("Clear saved areas", role: .destructive) { PersistentAreaCache.clear(); revision = UUID() }
            }
            Section("During an explicitly started walk") {
                Toggle("Continue with phone locked", isOn: $backgroundWalks)
                Toggle("Lock Screen Live Activity", isOn: $liveActivities)
                Text("These preferences apply the next time you start a walk. Pause or End stops its location updates. Live Activity content can be visible to anyone who can see your Lock Screen. Resume opens the app so location can restart reliably.").font(.caption).foregroundStyle(.secondary)
            }
        }.id(revision).pausePathSurface().navigationTitle("Saved areas & navigation").navigationBarTitleDisplayMode(.inline)
    }
}
