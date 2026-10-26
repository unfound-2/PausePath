import ActivityKit
import SwiftUI
import WidgetKit

private let mint = Color(red: 0.92, green: 0.99, blue: 0.96)
private let teal = Color(red: 0.01, green: 0.29, blue: 0.36)
private let lime = Color(red: 0.69, green: 0.91, blue: 0.16)

@main struct PausePathWidgets: WidgetBundle {
    var body: some Widget { WalkLiveActivity(); PlanWalkWidget() }
}
struct WalkLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WalkActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("PausePath", systemImage: "figure.walk").font(.headline)
                    Spacer()
                    Text(context.state.paused ? "Paused" : context.state.arrived ? "Finished" : "Walking").font(.caption.bold())
                }
                Text(context.isStale ? "Updates are out of date. Open PausePath to check your walk." : context.state.instruction)
                    .font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack {
                    Label(distance(context.state.remainingMeters, unit: context.state.distanceUnit) + " left", systemImage: "flag")
                    Spacer()
                    if !context.state.paused && !context.state.arrived {
                        Button(intent: PauseWalkIntent(sessionID: context.attributes.sessionID.uuidString)) { Label("Pause", systemImage: "pause.fill") }
                            .tint(teal)
                    } else if context.state.paused {
                        Link("Resume in app", destination: URL(string: "pausepath://walk/resume")!).fontWeight(.semibold)
                    }
                }.font(.caption)
                if let name = context.state.nextPause, let meters = context.state.nextPauseMeters {
                    Text("Next pause: " + name + " · " + distance(meters, unit: context.state.distanceUnit)).font(.caption).lineLimit(1)
                }
            }.padding(16).foregroundStyle(teal)
                .activityBackgroundTint(mint).activitySystemActionForegroundColor(teal)
                .widgetURL(URL(string: "pausepath://walk/current"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "figure.walk").foregroundStyle(lime) }
                DynamicIslandExpandedRegion(.trailing) { Text(distance(context.state.remainingMeters, unit: context.state.distanceUnit)).font(.headline).foregroundStyle(lime) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(context.isStale ? "Open PausePath for an update" : context.state.instruction).font(.subheadline).lineLimit(2)
                        if let name = context.state.nextPause { Text("Next pause: " + name).font(.caption).lineLimit(1) }
                        if context.state.paused {
                            Link("Resume in app", destination: URL(string: "pausepath://walk/resume")!)
                        } else if !context.state.arrived {
                            Button(intent: PauseWalkIntent(sessionID: context.attributes.sessionID.uuidString)) { Label("Pause walk", systemImage: "pause.fill") }.tint(lime)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.fill" : "figure.walk").foregroundStyle(lime)
            } compactTrailing: {
                Text(distance(context.state.remainingMeters, unit: context.state.distanceUnit)).font(.caption2).monospacedDigit().foregroundStyle(lime)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.fill" : "figure.walk").foregroundStyle(lime)
            }.widgetURL(URL(string: "pausepath://walk/current"))
        }
    }
    private func distance(_ meters: Int, unit: String?) -> String {
        if unit == "mi" {
            return meters < 161 ? String(format: "%.0f ft", Double(meters) / 0.3048) : String(format: "%.1f mi", Double(meters) / 1609.344)
        }
        return meters < 1000 ? "\(meters) m" : String(format: "%.1f km", Double(meters) / 1000)
    }
}
private struct WalkEntry: TimelineEntry { let date: Date }
private struct WalkProvider: TimelineProvider {
    func placeholder(in context: Context) -> WalkEntry { WalkEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (WalkEntry) -> Void) { completion(WalkEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WalkEntry>) -> Void) { completion(Timeline(entries: [WalkEntry(date: .now)], policy: .never)) }
}
struct PlanWalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PausePathPlanWalk", provider: WalkProvider()) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "figure.walk.circle.fill").font(.largeTitle).foregroundStyle(teal)
                Text("Make room for a pause.").font(.headline).foregroundStyle(teal)
                Text("Plan your next walk").font(.caption).foregroundStyle(teal)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .containerBackground(mint, for: .widget)
                .widgetURL(URL(string: "pausepath://explore"))
        }.configurationDisplayName("Plan a walk")
            .description("Open PausePath to explore stops and plan a walk. An active walk appears as a Live Activity.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
