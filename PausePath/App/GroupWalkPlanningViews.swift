import SwiftUI
import MapKit

struct GroupWalkComposer: View {
    let group: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title = "A walk together"
    @State private var meeting = ""
    @State private var details = ""
    @State private var date = Date().addingTimeInterval(3600)
    @State private var requestID = UUID()
    @State private var busy = false
    @State private var message = ""
    @State private var routes = SavedRouteStore.load()
    @State private var routeID: UUID?
    @State private var shareRoute = false
    @State private var meetingLocation: SharedRoutePoint?
    @State private var choosingMeeting = false
    private var selected: SavedRouteRecord? { routes.first { $0.id == routeID } }
    private var valid: Bool {
        (2...80).contains(title.trimmingCharacters(in: .whitespacesAndNewlines).count) && (1...160).contains(meeting.trimmingCharacters(in: .whitespacesAndNewlines).count) &&
        (1...500).contains(details.trimmingCharacters(in: .whitespacesAndNewlines).count) && (selected == nil || (shareRoute && (selected?.stopNames.count ?? 0) <= 12))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("The plan") {
                    TextField("Walk name", text: $title)
                    DatePicker("Start", selection: $date, in: Date()...)
                    TextField("Meeting point or address", text: $meeting).onChange(of: meeting) { _, _ in requestID = UUID() }
                    Button(meetingLocation == nil ? "Choose meeting point on map" : "Change mapped meeting point", systemImage: "mappin.and.ellipse") { choosingMeeting = true }
                    if let coordinate = meetingLocation?.coordinate {
                        Text("Mapped meeting point: \(coordinate.latitude, specifier: "%.4f"), \(coordinate.longitude, specifier: "%.4f")").font(.caption).foregroundStyle(.secondary)
                        Button("Remove map pin") { meetingLocation = nil; requestID = UUID() }
                    }
                }
                Section("Route & planned pauses") {
                    Picker("Saved route", selection: $routeID) {
                        Text("Describe a route instead").tag(UUID?.none)
                        ForEach(routes) { Text($0.title).tag(Optional($0.id)) }
                    }
                    if let selected {
                        SharedRouteMap(route: SharedRouteSnapshot(selected), meeting: meetingLocation)
                        Text("\(selected.distanceMeters / 1000, specifier: "%.1f") km · about \(Int(selected.estimatedSeconds / 60)) min · \(selected.stopNames.count) stops").font(.subheadline)
                        ForEach(Array(selected.stopNames.enumerated()), id: \.offset) { _, name in Label(name,systemImage: "mappin") }
                        Button("Meet at route start") {
                            meetingLocation = SharedRoutePoint(selected.origin); meeting = "Start of \(selected.title)"; requestID = UUID()
                        }
                        Toggle("Share this route and stops with the group",isOn: $shareRoute)
                        Text("The map is a saved plan, not live navigation. Stop access, opening hours and terrain may have changed.").font(.caption).foregroundStyle(.secondary)
                        if selected.stopNames.count > 12 { Text("Choose a route with at most 12 planned stops.").font(.caption) }
                    } else if routes.isEmpty {
                        Text("Plan and save a route in Explore to attach its map here.").font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Route and planned breaks",text: $details,axis: .vertical).lineLimit(3...6)
                }
                Section {
                    Text("Schedule shares the plan and any mapped meeting point with this community. Friends invited later must explicitly join the group before viewing the route. Recorded journeys and Health data are never attached.").font(.caption).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.callout) }
                }
            }.pausePathSurface().navigationTitle("Plan a group walk").navigationBarTitleDisplayMode(.inline)
                .onChange(of: routeID) { _, _ in
                    requestID = UUID(); shareRoute = false
                    if let selected { details = String("\(selected.title). Planned pauses: \(selected.stopNames.joined(separator: ", "))".prefix(500)) }
                }
                .onChange(of: [title,details,date.ISO8601Format(),String(shareRoute)]) { _, _ in requestID = UUID() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) { Button(busy ? "Saving…" : "Schedule") { Task { await save() } }.disabled(busy || !valid) }
                }.disabled(busy).interactiveDismissDisabled(busy)
                .sheet(isPresented: $choosingMeeting) {
                    MeetingPointPicker(initial: meetingLocation?.coordinate ?? selected?.origin) { coordinate, name in
                        meetingLocation = SharedRoutePoint(coordinate); meeting = String(name.prefix(160)); requestID = UUID()
                    }
                }
        }
    }
    @MainActor private func save() async {
        guard !busy, valid else { return }; busy = true; defer { busy = false }
        do {
            var body: [String: Any] = ["title":title,"meeting_point":meeting,"route_description":details,"starts_at":date.ISO8601Format(),"request_id":requestID.uuidString]
            if let selected, shareRoute { body["route_snapshot"] = SharedRouteSnapshot(selected).json }
            if let meetingLocation { body["meeting_location"] = ["type":"Point","coordinates":meetingLocation.coordinates] }
            _ = try await PausePathAPI.request("api/v1/communities/\(group)/walks",body: body,requiresAccount: true)
            await SocialActivityStore.shared.refresh(); dismiss()
        } catch { message = error.localizedDescription }
    }
}

private struct MeetingPointPicker: View {
    let initial: Coordinate?
    let onChoose: (Coordinate,String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic
    @State private var selected: Coordinate?
    @State private var name = "Meeting point"
    @State private var query = ""
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack {
                    TextField("Search a public meeting place",text: $query).textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }.disabled(busy || query.isEmpty)
                }.padding(.horizontal)
                MapReader { proxy in
                    Map(position: $camera) { if let selected { Marker(name,coordinate: selected.mapCoordinate) } }
                        .onTapGesture { point in
                            if let coordinate = proxy.convert(point,from: .local) { selected = Coordinate(coordinate.latitude,coordinate.longitude); name = "Mapped meeting point" }
                        }
                }
                Text("Tap the map to place a meeting pin. It will be shared with the group.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if !message.isEmpty { Text(message).font(.caption) }
            }.padding(.bottom).pausePathSurface().navigationTitle("Meeting point").navigationBarTitleDisplayMode(.inline)
                .onAppear { if let initial { selected = initial; camera = .region(MKCoordinateRegion(center:initial.mapCoordinate,latitudinalMeters:1200,longitudinalMeters:1200)) } }
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Use point") { if let selected { onChoose(selected,name); dismiss() } }.disabled(selected == nil) }
                }
        }
    }
    private func search() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
            let result = try await MKLocalSearch(request:request).start()
            guard let place = result.mapItems.first else { message = "No matching place found."; return }
            selected = Coordinate(place.placemark.coordinate.latitude,place.placemark.coordinate.longitude); name = place.name ?? query
            camera = .region(MKCoordinateRegion(center:place.placemark.coordinate,latitudinalMeters:1000,longitudinalMeters:1000))
        } catch { message = "Could not search. Try again when connected." }
    }
}

struct FriendsWalkInviteView: View {
    let walkID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var friends: [SocialFriend] = []
    @State private var sent = Set<UUID>()
    @State private var busy = false
    @State private var message = ""
    var body: some View {
        NavigationStack {
            List {
                Section { Text("Friends receive an invitation to join this community and RSVP. They choose whether to accept; no route is sent in the notification.").font(.callout) }
                ForEach(friends) { friend in
                    HStack {
                        Text("@\(friend.username)"); Spacer()
                        Button(sent.contains(friend.id) ? "Invited" : "Invite") { Task { await invite(friend) } }.disabled(busy || sent.contains(friend.id))
                    }
                }
                if friends.isEmpty { Text("Add friends in Profile → Friends to invite them here.").foregroundStyle(.secondary) }
                if !message.isEmpty { Text(message) }
            }.pausePathSurface().navigationTitle("Invite friends").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .task {
                    do { let result: FriendsResponse = try await SocialAPI.get("friends"); friends = result.friends.filter { $0.status == "accepted" } }
                    catch { message = error.localizedDescription }
                }
        }
    }
    private func invite(_ friend: SocialFriend) async {
        busy = true; defer { busy = false }
        do { try await SocialAPI.post("walks/\(walkID)/invite",["person_id":friend.person_id.uuidString]); sent.insert(friend.id); message = "Invitation sent to @\(friend.username)." }
        catch { message = error.localizedDescription }
    }
}

struct SharedGroupRouteView: View {
    let route: SharedRouteSnapshot
    let meeting: SharedRoutePoint?
    @State private var busy = false
    @State private var message = ""
    @State private var walk: GeneratedWalk?
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            SharedRouteMap(route: route,meeting: meeting)
            ForEach(Array(route.stops.enumerated()),id: \.offset) { _, stop in Label(stop.name,systemImage: "mappin") }
            Button(busy ? "Checking current directions…" : "Refresh stops & preview walk",systemImage: "figure.walk") { Task { await rebuild() } }.disabled(busy)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.sheet(item: $walk) { WalkingNavigationView(walk: $0) }
    }
    private func rebuild() async {
        guard let record = route.replayRecord, !busy else { return }; busy = true; message = ""; defer { busy = false }
        do {
            let data = UserDefaults.standard.data(forKey: "pausepath.preferences") ?? Data()
            let preferences = (try? JSONDecoder().decode(RoutePreferences.self,from: data)) ?? RoutePreferences()
            walk = try await RouteLibrary.repeatRoute(record,preferences: preferences)
        } catch { message = error.localizedDescription }
    }
}
