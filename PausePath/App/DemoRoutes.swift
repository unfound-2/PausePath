import Foundation

enum DemoRoutes {
    static func make(departure: Date) -> [WalkingRoute] {
        // Synthetic fixtures, not surveyed facilities or navigable route geometry.
        let points = [Coordinate(41.8826, -87.6226), Coordinate(41.8852, -87.6226), Coordinate(41.8852, -87.6190), Coordinate(41.8826, -87.6190), Coordinate(41.8826, -87.6226)]
        let hours = [OpeningWindow(start: departure.addingTimeInterval(-3600), end: departure.addingTimeInterval(7200))]
        return [("short", "A little fresh air", 800.0, 2.0), ("steady", "A steady loop", 1200.0, 2.5), ("long", "Room to explore", 2000.0, 5.0)].map { id, name, meters, grade in
            let seats = stride(from: 200.0, to: meters, by: 200).enumerated().map { index, offset in
                RouteFacility(id: "\(id)-seat-\(index)", name: "Sample bench \(index + 1)", kind: .bench, coordinate: points[index % 4], metersFromStart: offset, hasSeating: true, openingWindows: hours)
            }
            let amenities: [RouteFacility] = [
                RouteFacility(id: "\(id)-wc", name: "Sample bathroom", kind: .bathroom, coordinate: points[1], metersFromStart: 300, hasSeating: false, openingWindows: hours),
                RouteFacility(id: "\(id)-water", name: "Sample fountain", kind: .fountain, coordinate: points[2], metersFromStart: 500, hasSeating: false, openingWindows: nil),
                RouteFacility(id: "\(id)-cafe", name: "Sample café", kind: .cafe, coordinate: points[3], metersFromStart: 600, hasSeating: true, openingWindows: hours)
            ]
            return WalkingRoute(id: id, name: name, meters: meters, maximumGradePercent: grade, coordinates: points, facilities: seats + amenities)
        }
    }
}
