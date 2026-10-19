import SwiftUI

struct RouteDifficultyPreview: View {
    let input: RouteDifficultyInput
    var compact = false
    @AppStorage(RouteDifficultyPreferences.storageKey)
    private var factorSelection = RouteDifficultyPreferences.defaultStorageValue
    @State private var showingDetails = false

    private var assessment: RouteDifficultyAssessment {
        RouteDifficultyCalculator.assess(input, preferences: RouteDifficultyPreferences(storageValue: factorSelection))
    }

    var body: some View {
        Group {
            if compact {
                Button { showingDetails = true } label: {
                    Label("Difficulty: \(assessment.label)", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityHint("Shows the factors and missing data behind this rating")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(assessment.label, systemImage: assessment.rating == nil ? "info.circle" : "figure.walk")
                            .font(.subheadline.weight(.semibold))
                            .accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button("Why this rating?") { showingDetails = true }
                            .font(.subheadline)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                    Text("A planning aid, not a measure of your fitness or ability.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let message = assessment.limitedInformationMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            RouteDifficultyDetailView(input: input)
        }
    }
}

struct RouteDifficultyFactorSettings: View {
    @AppStorage(RouteDifficultyPreferences.storageKey)
    private var factorSelection = RouteDifficultyPreferences.defaultStorageValue

    private var preferences: RouteDifficultyPreferences {
        RouteDifficultyPreferences(storageValue: factorSelection)
    }

    var body: some View {
        Section("Route difficulty factors") {
            Text("Choose which factors matter to your rating. PausePath uses available selected factors when some route data is missing. A known demanding factor can still raise the overall label so it isn’t hidden.")
                .font(.callout)
            ForEach(RouteDifficultyFactor.allCases) { factor in
                Toggle(factor.title, isOn: Binding(
                    get: { preferences.includedFactors.contains(factor) },
                    set: { isIncluded in
                        var updated = preferences.includedFactors
                        if isIncluded { updated.insert(factor) } else { updated.remove(factor) }
                        factorSelection = RouteDifficultyPreferences(includedFactors: updated).storageValue
                    }
                ))
            }
            Text("These choices stay on this device and are not based on Health data. Route difficulty is a planning aid, not a judgment of your ability.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

private struct RouteDifficultyDetailView: View {
    let input: RouteDifficultyInput
    @AppStorage(RouteDifficultyPreferences.storageKey)
    private var factorSelection = RouteDifficultyPreferences.defaultStorageValue
    @Environment(\.dismiss) private var dismiss

    private var assessment: RouteDifficultyAssessment {
        RouteDifficultyCalculator.assess(input, preferences: RouteDifficultyPreferences(storageValue: factorSelection))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(assessment.label)
                        .font(.title3.bold())
                    Text("This planning aid describes route factors. It does not measure your fitness or ability, and it is not medical advice.")
                        .font(.callout)
                    if let message = assessment.limitedInformationMessage {
                        Label(message, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Route factors") {
                    ForEach(assessment.factors) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.factor.title).font(.headline)
                                Spacer()
                                Text(statusLabel(for: result))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(statusColor(for: result))
                            }
                            Text(result.detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if !result.isIncluded {
                                Text("Not included in your selected factors. Known demanding factors still affect the overall label.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                Section {
                    Text("Comparisons may be unreliable when routes have different data coverage. Surface, stairs, elevation, and rest-stop data are shown only when a source provides them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("How the label is set") {
                    Text("Available selected factors are averaged across broad planning ranges. The most demanding known factor sets a minimum label, even if you did not select it, so a low average cannot hide a demanding route factor. When some selected factors are missing, the label still uses known route details and this view identifies the gaps; comparisons may be unreliable when data coverage differs.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Why this rating?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func statusLabel(for result: RouteDifficultyFactorResult) -> String {
        if !result.isIncluded {
            return result.status == .complete ? "Available · not included" : "Not included · \(dataStatus(result.status))"
        }
        if result.status == .complete, let level = result.level { return level.rawValue }
        return dataStatus(result.status)
    }

    private func dataStatus(_ status: RouteDifficultyDataStatus) -> String {
        switch status {
        case .complete: "Available"
        case .incomplete: "Incomplete"
        case .unavailable: "Unavailable"
        }
    }

    private func statusColor(for result: RouteDifficultyFactorResult) -> Color {
        guard result.isIncluded, result.status == .complete else { return .secondary }
        switch result.level {
        case .some(.easy): return .green
        case .some(.moderate): return .orange
        case .some(.hard): return .red
        case .none: return .secondary
        }
    }
}
