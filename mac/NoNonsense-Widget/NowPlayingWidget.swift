import SwiftUI
import WidgetKit

/// The Mac's widget (29 Oct): the song playing, with its cover; tapping it opens the app. The app writes what it shows
/// (Services/WidgetFeed.swift) and asks for a reload when the song or play/pause changes; this extension is sandboxed,
/// so it reads those two files through a read-only exception for the app's own folder, and makes no network request.
@main
struct NoNonsenseWidgets: WidgetBundle {
    var body: some Widget { NowPlayingWidget() }
}

struct NowPlaying: Codable {
    let title: String
    let artist: String
    let playing: Bool
}

struct Entry: TimelineEntry {
    let date: Date
    let song: NowPlaying?
    let cover: Data?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: .now, song: NowPlaying(title: "Song", artist: "Artist", playing: true), cover: nil) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Self.read()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Self.read()], policy: .never))      // the app reloads it when something changes
    }

    /// The app's folder in the real home (a sandboxed process's own home is its container): the app's bundle id is this
    /// extension's without ".widget".
    static func read() -> Entry {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir.map({ String(cString: $0) }),
              let id = Bundle.main.bundleIdentifier?.replacingOccurrences(of: ".widget", with: "") else { return Entry(date: .now, song: nil, cover: nil) }
        let folder = URL(filePath: home).appending(path: "Library/Application Support/\(id)")
        let song = (try? Data(contentsOf: folder.appending(path: "widget.json"))).flatMap { try? JSONDecoder().decode(NowPlaying.self, from: $0) }
        return Entry(date: .now, song: song, cover: song == nil ? nil : try? Data(contentsOf: folder.appending(path: "cover.jpg")))
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: Provider()) { entry in
            WidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing. Click to open the app.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct WidgetView: View {
    let entry: Entry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let song = entry.song {
                if family == .systemSmall { small(song) } else { medium(song) }
            } else {
                Text("Nothing playing").font(.headline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .widgetURL(URL(string: "nononsense://open"))
    }

    /// The cover, or a dark tile with a small note when there is none (not written yet, or not readable). The symbol itself
    /// used to be scaled to fill the widget, which drew a big white blob where the picture should be.
    @ViewBuilder private var cover: some View {
        if let image = entry.cover.flatMap(NSImage.init(data:)) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.white.opacity(0.1)
                Image(systemName: "music.note").font(.system(size: 30)).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func small(_ song: NowPlaying) -> some View {
        ZStack(alignment: .bottomLeading) {
            cover
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(song.artist).font(.caption).opacity(0.75).lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(10)
        }
    }

    private func medium(_ song: NowPlaying) -> some View {
        HStack(spacing: 14) {
            cover.frame(width: 112, height: 112).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(song.playing ? "Playing" : "Paused").font(.caption.weight(.semibold)).textCase(.uppercase).opacity(0.6)
                Text(song.title).font(.headline).lineLimit(2)
                Text(song.artist).font(.subheadline).opacity(0.75).lineLimit(1)
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }
}
