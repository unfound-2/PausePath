import SwiftUI
import MapKit

struct SavedAreasSettingsView: View {
    @State private var revision = UUID()
    @State private var query = ""
    @State private var width = 4000.0
    @State private var busy = false
    @State private var message = ""
    @State private var pendingDelete: String?
    @State private var clearAll = false
    @AppStorage("pausepath.walk.suggestAlternatives") private var suggestAlternatives = true
    @AppStorage("pausepath.walk.background") private var backgroundWalks = true
    @AppStorage("pausepath.walk.liveActivity") private var liveActivities = true
    var body: some View {
        Form {
            Section("Download stop information") {
                TextField("City, neighborhood or address", text: $query).submitLabel(.search).onSubmit { Task { await download() } }
                Picker("Area width", selection: $width) { Text("1 km").tag(1000.0); Text("2 km").tag(2000.0); Text("4 km").tag(4000.0) }
                Button(busy ? "Fetching mapped stops…" : "Save area", systemImage: "arrow.down.circle") { Task { await download() } }.disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Saves the selected area around your search. Large cities need several areas. Only mapped stop details are saved; street maps and offline directions are not included.").font(.caption).foregroundStyle(.secondary)
                if !message.isEmpty { Text(message).font(.callout) }
            }
            Section("On this phone") {
                LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: Int64(PersistentAreaCache.bytes), countStyle: .file))
                ForEach(PersistentAreaCache.areas) { area in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(area.label).font(.headline)
                        Text("\(area.count) saved stops · updated \(area.savedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        if Date().timeIntervalSince(area.savedAt) > 7 * 86400 { Label("Older information — refresh before relying on it", systemImage: "clock").font(.caption) }
                        HStack {
                            Button(area.pinned ? "Unpin" : "Keep saved", systemImage: area.pinned ? "pin.fill" : "pin") { PersistentAreaCache.pin(area.key); revision = UUID() }
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh(area.key) } }.disabled(busy)
                            Spacer()
                            Button("Remove", systemImage: "trash", role: .destructive) { pendingDelete = area.key }
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(.vertical, 5)
                }
                if PersistentAreaCache.count == 0 { Text("No saved areas yet.").foregroundStyle(.secondary) }
                Text("Up to eight areas and 2,500 stops per area within 5 MB. Unpinned areas expire after seven days and are replaced first. The storage limit still applies to pinned areas. Business information from Mapbox is excluded; saved details can be outdated.").font(.caption).foregroundStyle(.secondary)
                Button("Clear saved areas", role: .destructive) { clearAll = true }.disabled(PersistentAreaCache.count == 0)
            }
            Section("During an explicitly started walk") {
                Toggle("Suggest alternatives for unavailable stops", isOn: $suggestAlternatives)
                Toggle("Continue with phone locked", isOn: $backgroundWalks)
                Toggle("Lock Screen Live Activity", isOn: $liveActivities)
                Text("Applies to your next walk. Pause or End stops location updates. Lock Screen information can be visible to others. Resume opens the app.").font(.caption).foregroundStyle(.secondary)
            }
        }.id(revision).pausePathSurface().navigationTitle("Downloaded areas").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Remove this saved area?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Remove area", role: .destructive) { if let key = pendingDelete { PersistentAreaCache.remove(key); revision = UUID() }; pendingDelete = nil }
            }
            .confirmationDialog("Clear all saved stop information?", isPresented: $clearAll, titleVisibility: .visible) {
                Button("Clear areas", role: .destructive) { PersistentAreaCache.clear(); revision = UUID() }
            }
    }
    @MainActor private func download() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
            let response = try await MKLocalSearch(request: request).start()
            guard let item = response.mapItems.first else { message = "No matching area found. Try a more specific name."; return }
            let region = MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: width, longitudinalMeters: width)
            let key = PersistentAreaCache.key(for: region)
            try await fetch(region, key: key)
            if PersistentAreaCache.areas.first(where: { $0.key == key })?.pinned != true { PersistentAreaCache.pin(key, label: item.name ?? query) }
            revision = UUID()
        } catch { message = error.localizedDescription }
    }
    @MainActor private func refresh(_ key: String) async {
        guard !busy, let region = PersistentAreaCache.region(for: key) else { return }
        busy = true; defer { busy = false }
        do { try await fetch(region, key: key); revision = UUID() } catch { message = "Could not refresh. Your saved details are retained." }
    }
    @MainActor private func fetch(_ region: MKCoordinateRegion, key: String) async throws {
        let response = try await PausePathAPI.search(region)
        if response.loading_state == "ready" || !response.pois.isEmpty {
            guard PersistentAreaCache.save(key: key, places: response.pois.compactMap(\.place)) else {
                throw ServiceFailure(status: 409, message: "This area could not be saved. Unpin or remove an area to make space, then try again.")
            }
        }
        message = response.loading_state == "ready" && !response.truncated ? "Available mapped stops saved. Availability can change." : "This area is still being collected. Any available stops were saved; refresh later for more coverage."
    }
}
