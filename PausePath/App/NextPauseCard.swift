import SwiftUI
import MapKit

struct NextPauseCard: View {
    let navigator: WalkingNavigator
    @State private var alternatives: [(poi: SharedPOI, meters: Double)] = []
    @State private var message = ""
    @State private var busy = false
    @State private var report: DiscoveredPlace?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Your next pause", systemImage: "chair.fill").font(.headline).foregroundStyle(PausePathPalette.teal)
            if let next = navigator.nextPause, let plan = navigator.plan {
                let poi = navigator.stopStatuses[next.place.id] ?? next.place.shared
                let arrival = Date().addingTimeInterval(next.meters / max(0.3, plan.preferences.speedMetersPerSecond) + Double(max(0, next.index - navigator.progress.legIndex)) * 300)
                Text(next.place.item.name ?? "Mapped bench").font(.title3.bold())
                Text("\(Int(next.meters.rounded())) m along the planned route · about \(max(1, Int(ceil(next.meters / max(0.3, plan.preferences.speedMetersPerSecond) / 60)))) min").font(.subheadline)
                Text(poi?.availabilityDescription(at: arrival) ?? "Opening hours at arrival unknown").font(.caption.weight(.semibold))
                Text(poi?.attributes?.summary ?? "Access, backrest and shade unknown").font(.caption).foregroundStyle(.secondary)
                Text("Last community verification: \(poi?.verificationDescription ?? "Unknown")").font(.caption).foregroundStyle(.secondary)
                if !navigator.freshLocation() { Text("Distance uses your last accepted route position. Waiting for fresh GPS.").font(.caption).foregroundStyle(.secondary) }
                if poi?.unavailable == true || poi?.reportedUnavailable == true {
                    Label("Reported unavailable. Choose another pause before relying on it.", systemImage: "exclamationmark.triangle").font(.callout)
                }
                HStack {
                    Button("Find another pause", systemImage: "arrow.triangle.swap") { Task { await findAlternatives() } }.disabled(busy)
                    Spacer()
                    Button("Report", systemImage: "flag") { report = (poi?.place ?? next.place) }
                }.font(.subheadline).frame(minHeight: 44)
                ForEach(alternatives, id: \.poi.id) { alternative in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(alternative.poi.name ?? "Alternative bench").font(.subheadline.bold())
                        Text("\(Int(alternative.meters)) m walking to this stop · remaining route will change").font(.caption)
                        Text(alternative.poi.availabilityDescription(at: Date().addingTimeInterval(alternative.meters / max(0.3, plan.preferences.speedMetersPerSecond)))).font(.caption)
                        Button("Use this alternative") {
                            Task { await navigator.replaceNextPause(with: alternative.poi); alternatives = [] }
                        }.disabled(navigator.isRecalculating || !navigator.freshLocation()).buttonStyle(.bordered)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(PausePathPalette.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                Text("No upcoming bench is included in this route.").font(.subheadline)
                Text("The requested rest interval is not guaranteed. You can pause the walk or review another route.").font(.caption).foregroundStyle(.secondary)
            }
            if busy { ProgressView("Checking walking access…") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PausePathPalette.surface, in: RoundedRectangle(cornerRadius: PausePathPalette.corner))
            .overlay(RoundedRectangle(cornerRadius: PausePathPalette.corner).strokeBorder(PausePathPalette.teal.opacity(0.1)))
            .task(id: navigator.nextPause?.place.id) {
                await refreshStatus()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    if scenePhase == .active { await refreshStatus() }
                }
            }
            .sheet(item: $report) { place in
                StopReportView(place: place, coordinate: place.item.placemark.coordinate) { Task { await refreshStatus() } }
            }
    }
    private func refreshStatus() async {
        guard let next = navigator.nextPause, next.place.shared != nil else { return }
        do {
            let data = try await PausePathAPI.request("api/v1/pois/\(next.place.id.uuidString)")
            let poi = try JSONDecoder().decode(SharedPOI.self, from: data)
            guard !Task.isCancelled else { return }
            navigator.stopStatuses[poi.id] = poi
            if poi.unavailable || poi.reportedUnavailable { message = "The latest report marks this pause unavailable. Alternatives are available below." }
            else { message = "Status checked just now. Listing data can change." }
            navigator.updateActivity(force: true)
        } catch { if !Task.isCancelled { message = "Could not refresh this stop. Last known information is shown." } }
    }
    private func findAlternatives() async {
        guard let plan = navigator.plan else { return }
        busy = true; alternatives = []; message = ""
        defer { busy = false }
        let origin = navigator.freshLocation() ? navigator.location!.coordinate : plan.start.mapCoordinate
        do {
            let region = MKCoordinateRegion(center: origin, latitudinalMeters: 1600, longitudinalMeters: 1600)
            let result = try await PausePathAPI.search(region)
            let candidates = result.pois.filter {
                $0.category == "bench" && !$0.unavailable && !$0.reportedUnavailable && !$0.restrictedAccess && $0.id != navigator.nextPause?.place.id
            }.sorted {
                WalkingGeometry.distance(Coordinate(origin.latitude, origin.longitude), Coordinate($0.coordinate.latitude, $0.coordinate.longitude)) < WalkingGeometry.distance(Coordinate(origin.latitude, origin.longitude), Coordinate($1.coordinate.latitude, $1.coordinate.longitude))
            }
            for candidate in candidates.prefix(4) {
                try Task.checkCancellation()
                do {
                let route = try await WalkingDirections.route(from: Coordinate(origin.latitude, origin.longitude), to: Coordinate(candidate.coordinate.latitude, candidate.coordinate.longitude), departure: .now)
                let arrival = Date().addingTimeInterval(route.distance / max(0.3, plan.preferences.speedMetersPerSecond))
                guard candidate.openAtArrival(arrival) != false,
                      plan.allowUnknownRestStops || (candidate.openAtArrival(arrival) == true && candidate.accessDescription == "public"),
                      let endpoint = route.polyline.walkingCoordinates.last,
                      WalkingGeometry.distance(endpoint, Coordinate(candidate.coordinate.latitude, candidate.coordinate.longitude)) <= 30 else { continue }
                alternatives.append((candidate, route.distance))
                } catch { if Task.isCancelled { return } }
                if alternatives.count == 3 { break }
            }
            message = alternatives.isEmpty ? "No suitable mapped alternative was found nearby. Data may be incomplete; pause or review your route." : "Compare the alternatives. Choosing one recalculates the remaining walk and rest gap."
        } catch { message = "Alternatives could not load. Your current route is retained." }
    }
}
