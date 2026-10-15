import SwiftUI
import WidgetKit

/// The widgets (#22): the song playing, on the desktop and in Notification Centre. A first, plain version: does macOS
/// list an extension signed as this app is (ad hoc, no developer team)?
@main
struct NoNonsenseWidgets: WidgetBundle {
    var body: some Widget { NowPlayingWidget() }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { _ in
            Text("NoNonsenseMusic")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing, with its controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

nonisolated struct NowPlayingEntry: TimelineEntry {
    let date: Date
}

nonisolated struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { NowPlayingEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(NowPlayingEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [NowPlayingEntry(date: .now)], policy: .never))
    }
}
