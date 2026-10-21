import Foundation
import MapKit

/// Public map data is stored only on this phone, with timestamps and a hard disk budget.
@MainActor enum PersistentAreaCache {
    private struct Facility: Codable {
        let id: UUID; let name: String?; let kind: FacilityKind; let coordinate: Coordinate
        let shared: SharedPOI?; let provider: String; let businessID: String?; let businessSummary: String?; let website: URL?
        init(_ place: DiscoveredPlace) {
            id = place.id; name = place.item.name; kind = place.kind
            coordinate = Coordinate(place.item.placemark.coordinate.latitude, place.item.placemark.coordinate.longitude)
            shared = place.shared; provider = place.provider; businessID = place.businessID; businessSummary = place.businessSummary; website = place.website
        }
        var place: DiscoveredPlace? {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite, (-90...90).contains(coordinate.latitude), (-180...180).contains(coordinate.longitude) else { return nil }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate.mapCoordinate)); item.name = name
            return DiscoveredPlace(id: id, item: item, kind: kind, shared: shared, provider: provider, businessID: businessID, businessSummary: businessSummary, website: website)
        }
    }
    private struct Entry: Codable { let key: String; let savedAt: Date; let facilities: [Facility] }
    struct Snapshot { let key: String; let savedAt: Date; let places: [DiscoveredPlace] }
    private static let maximumBytes = 5 * 1024 * 1024
    private static var entries: [Entry] = read()
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PausePath/saved-areas-v1.json")
    }
    private static func read() -> [Entry] {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumBytes,
              let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(values.filter { $0.savedAt <= Date().addingTimeInterval(60) && Date().timeIntervalSince($0.savedAt) < 7 * 86400 }.prefix(8))
    }
    static func load(_ key: String) -> Snapshot? {
        entries.first { $0.key == key }.map { Snapshot(key: $0.key, savedAt: $0.savedAt, places: $0.facilities.compactMap(\.place)) }
    }
    static var mostRecent: Snapshot? { entries.first.flatMap { load($0.key) } }
    static var count: Int { entries.count }
    static var bytes: Int { (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
    static func save(key: String, places: [DiscoveredPlace], at date: Date = .now) {
        // A successful empty response replaces stale records too.
        entries.removeAll { $0.key == key }
        entries.insert(Entry(key: key, savedAt: date, facilities: places.filter { $0.provider != "Mapbox" }.prefix(2500).map(Facility.init)), at: 0)
        entries = Array(entries.prefix(8))
        do {
            var data = try JSONEncoder().encode(entries)
            while data.count > maximumBytes && !entries.isEmpty { entries.removeLast(); data = try JSONEncoder().encode(entries) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            var resource = URLResourceValues(); resource.isExcludedFromBackup = true
            var destination = file; try destination.setResourceValues(resource)
        } catch { /* A disk failure never blocks map discovery. */ }
    }
    static func clear() {
        entries = []
        try? FileManager.default.removeItem(at: file)
        NotificationCenter.default.post(name: .pausePathSavedAreasCleared, object: nil)
    }
}

extension Notification.Name {
    static let pausePathSavedAreasCleared = Notification.Name("pausepath.savedAreasCleared")
    static let pausePathOpenExplore = Notification.Name("pausepath.openExplore")
}
