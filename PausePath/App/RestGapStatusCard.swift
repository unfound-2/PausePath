import SwiftUI

struct RestGapStatusCard: View {
    @AppStorage(DistanceDisplayUnit.storageKey) private var distanceUnitRaw = DistanceDisplayUnit.kilometers.rawValue
    private var distanceUnit: DistanceDisplayUnit { DistanceDisplayUnit(rawValue: distanceUnitRaw) ?? .kilometers }

    let assessment: RestGapAssessment
    let limit: Double
    private var title: String {
        switch assessment.status {
        case .meets: "Listed rest stops meet your \(distanceUnit.nearby(limit)) gap"
        case .unverified: "Mapped gap fits · availability unverified"
        case .exceeds: "Requested rest gap cannot be met"
        case .unknown: "Rest-gap data is incomplete"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: assessment.status == .meets ? "checkmark.circle" : "exclamationmark.circle").font(.subheadline.weight(.semibold))
            if let gap = assessment.longestGap {
                Text("Longest gap: \(distanceUnit.nearby(gap)) · maximum: \(distanceUnit.nearby(limit))").font(.caption)
            }
            if assessment.status == .exceeds { Text("Try a shorter route, another destination, or change your own rest preference. This route remains available with its limitation shown.").font(.caption) }
            if assessment.uncertainStops > 0 { Text("\(assessment.uncertainStops) mapped benches have unknown hours or public access. Listing data is not a live guarantee.").font(.caption) }
        }.foregroundStyle(PausePathPalette.teal).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(PausePathPalette.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
    }
}
