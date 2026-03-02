import SwiftUI
import WidgetKit

struct RelayQuickLaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> RelayQuickLaunchEntry {
        RelayQuickLaunchEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (RelayQuickLaunchEntry) -> Void) {
        completion(RelayQuickLaunchEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RelayQuickLaunchEntry>) -> Void) {
        let entry = RelayQuickLaunchEntry(date: .now)
        // Static widget — never needs refresh
        let timeline = Timeline(entries: [entry], policy: .never)
        completion(timeline)
    }
}

struct RelayQuickLaunchEntry: TimelineEntry {
    let date: Date
}

struct RelayQuickLaunchView: View {
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "ellipsis.bubble")
                .font(.system(size: 24, weight: .semibold))
                .widgetAccentable()
        }
        .widgetURL(URL(string: "relay://live")!)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct RelayQuickLaunchWidget: Widget {
    let kind = "RelayQuickLaunch"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RelayQuickLaunchProvider()) { _ in
            RelayQuickLaunchView()
        }
        .configurationDisplayName("Relay Live")
        .description("Tap to enter live mode.")
        .supportedFamilies([.accessoryCircular])
    }
}
