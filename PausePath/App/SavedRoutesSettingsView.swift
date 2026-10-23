import SwiftUI
import MapKit

struct SharedRouteMap: View {
    let route: SharedRouteSnapshot
    var meeting: SharedRoutePoint? = nil
    var body: some View {
        Map {
            if route.coordinates.count > 1 { MapPolyline(coordinates: route.coordinates).stroke(PausePathPalette.teal, lineWidth: 5) }
            if let coordinate = meeting?.coordinate { Marker("Meeting point", systemImage: "person.2.fill", coordinate: coordinate.mapCoordinate).tint(.orange) }
            ForEach(Array(route.stops.enumerated()), id: \.offset) { _, stop in
                if let coordinate = stop.location.coordinate {
                    Marker(stop.name, systemImage: FacilityKind.fromAPI(stop.category)?.symbol ?? "mappin", coordinate: coordinate.mapCoordinate)
                }
            }
        }.mapControls { MapCompass(); MapScaleView() }.frame(height: 230).clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityLabel("Shared route preview and planned stops")
    }
}

struct SavedRoutesSettingsView: View {
    let preferences: RoutePreferences
    @State private var routes = SavedRouteStore.load()
    @State private var filter = "All"
    @State private var query = ""
    private var collections: [String] { Array(Set(routes.compactMap(\.collection).filter { !$0.isEmpty })).sorted() }
    private var filtered: [SavedRouteRecord] {
        routes.filter { (filter == "All" || (filter == "Favorites" ? $0.isFavorite == true : $0.collection == filter)) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.destinationName.localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            Section {
                Picker("Show", selection: $filter) {
                    Text("All routes").tag("All"); Text("Favorites").tag("Favorites")
                    ForEach(collections.filter { $0 != "All" && $0 != "Favorites" }, id: \.self) { Text($0).tag($0) }
                }
                Text("Saved on this phone. Repeating a route rebuilds walking directions and checks its mapped stops; maps and new directions require a connection.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(filtered) { record in
                NavigationLink { SavedRouteDetailView(record: record, preferences: preferences) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(record.title).font(.headline); if record.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(PausePathPalette.teal) } }
                        Text("\(record.distanceMeters / 1000, specifier: "%.1f") km · \(record.stopNames.count) planned stops").font(.subheadline).foregroundStyle(.secondary)
                        if let collection = record.collection, !collection.isEmpty { Text(collection).font(.caption) }
                    }.padding(.vertical, 5)
                }.swipeActions { Button("Delete", role: .destructive) { SavedRouteStore.delete(record.id); reload() } }
            }
            if filtered.isEmpty { ContentUnavailableView("No saved routes", systemImage: "heart", description: Text("Plan a route in Explore, then save it from its navigation preview.")) }
        }.searchable(text: $query, prompt: "Search saved routes").pausePathSurface().navigationTitle("Saved routes")
            .navigationBarTitleDisplayMode(.inline).onAppear(perform: reload)
    }
    private func reload() { routes = SavedRouteStore.load() }
}

struct SavedRouteDetailView: View {
    @State var record: SavedRouteRecord
    let preferences: RoutePreferences
    @State private var collection = ""
    @State private var busy = false
    @State private var message = ""
    @State private var walk: GeneratedWalk?
    @State private var updatedAt: Date?
    var body: some View {
        Form {
            Section {
                SharedRouteMap(route: SharedRouteSnapshot(record))
                Text("\(record.distanceMeters / 1000, specifier: "%.1f") km · about \(Int(record.estimatedSeconds / 60)) min").font(.headline)
                Text("Saved \(record.savedAt.formatted(date: .abbreviated, time: .shortened)) · terrain and availability may have changed.").font(.caption).foregroundStyle(.secondary)
                if !record.stopNames.isEmpty && record.stops == nil { Text("This older saved route needs rebuilding in Explore to restore stop locations.").font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(record.stopNames.enumerated()), id: \.offset) { _, name in Label(name, systemImage: "mappin.and.ellipse") }
            } header: { Text("Saved preview") }
            Section("Organize") {
                Toggle("Favorite", isOn: Binding(get: { record.isFavorite == true }, set: { record.isFavorite = $0; SavedRouteStore.update(record) }))
                TextField("Collection name", text: $collection).onChange(of: collection) { _, value in
                    record.collection = String(value.prefix(40)); SavedRouteStore.update(record)
                }
            }
            Section("Walk again") {
                Button(busy ? "Checking route and stops…" : "Refresh stops & preview walk", systemImage: "arrow.clockwise") { Task { await rebuild() } }.disabled(busy)
                if let updatedAt { Text("Checked \(updatedAt.formatted(date: .omitted, time: .shortened))").font(.caption) }
                if !message.isEmpty { Text(message).font(.callout) }
            }
        }.pausePathSurface().navigationTitle(record.title).navigationBarTitleDisplayMode(.inline)
            .onAppear { collection = record.collection ?? "" }
            .sheet(item: $walk) { WalkingNavigationView(walk: $0) }
    }
    @MainActor private func rebuild() async {
        busy = true; message = ""; defer { busy = false }
        do { walk = try await RouteLibrary.repeatRoute(record, preferences: preferences); updatedAt = .now }
        catch { message = error.localizedDescription }
    }
}
