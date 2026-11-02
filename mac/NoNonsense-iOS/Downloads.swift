import SwiftUI

/// Songs kept on this iPhone: they play without the server or the internet.
struct DownloadsScreen: View {
    @Environment(DownloadStore.self) private var downloads
    @State private var confirming = false

    var body: some View {
        let tracks = downloads.tracks
        Group {
            if tracks.isEmpty {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Press and hold a song › Download, or use a playlist's or album's menu. Downloads play without the server or the internet."))
            } else {
                SongsScreen(title: "Downloads", tracks: tracks, source: "downloads", symbol: "arrow.down.circle",
                            remove: { i in if let track = tracks[safe: i] { downloads.remove(track) } })
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !tracks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Remove All Downloads", role: .destructive) { confirming = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Downloads options")
                }
            }
        }
        .confirmationDialog(tracks.count == 1 ? "Remove this download?" : "Remove all \(tracks.count) downloads?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(tracks.count == 1 ? "Remove" : "Remove All", role: .destructive) { downloads.removeAll() }
        } message: {
            Text("They stay in your library and still play from the internet.")
        }
    }
}

/// An album's menu: download it, keep it on Home (a pinned copy in your playlists) or take it off.
struct AlbumMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    let ref: AlbumRef
    let title: String
    let tracks: [Track]

    var body: some View {
        Menu {
            Button { Task { await downloads.download(all: tracks, name: title) } } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(tracks.isEmpty)
            if let pinned = library.pinned(ref) {
                Button { Task { await library.unpin(pinned) } } label: { Label("Remove from Home", systemImage: "pin.slash") }
            } else {
                Button { Task { await library.pin(ref) } } label: { Label("Keep on Home", systemImage: "pin") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Album options")
    }
}
