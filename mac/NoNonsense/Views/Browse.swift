import SwiftUI

/// A page opened from inside a screen: an artist or an album. Pushed onto the window's navigation stack, so the
/// toolbar shows a back button; choosing a sidebar item starts the stack afresh.
enum Route: Hashable {
    case artist(ArtistRef)
    case album(AlbumRef)
    /// An artist known only by name (a song's artist line): the best match from a search opens.
    case artistNamed(String)
    /// An album known only by its title and artist (a song's album): the best match from a search opens.
    case albumNamed(title: String, artist: String)
}

/// The window's navigation stack, shared so that Now Playing (in its own host) and the song menus can open a page.
@Observable
final class Navigator {
    static let shared = Navigator()
    var path: [Route] = []
    /// A playlist to show (a notification's Open Playlist): RootView selects it and clears this.
    var playlistRequest: UUID?

    /// Opens a page over the current screen; the same page twice in a row is not stacked.
    func open(_ route: Route) {
        if path.last != route { path.append(route) }
    }

    /// Back to the page or screen under this one.
    func back() { if !path.isEmpty { path.removeLast() } }
}

/// The toolbar's Back while a page is open (⌘[, as in Finder and Safari).
struct BackButton: View {
    var body: some View {
        if !Navigator.shared.path.isEmpty {
            Button { Navigator.shared.back() } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                .accessibilityLabel("Back")
        }
    }
}

extension EnvironmentValues {
    /// True for the screen under an open artist or album page: it keeps its state but must not set the window's title.
    @Entry var pageCovered = false
}

/// The window's title, from whichever screen or page is visible (ScrollTitle sets it). One place sets
/// `navigationTitle`, so the hidden screen under a page never competes with the page for the title bar.
struct TitleBarTitle: View {
    var body: some View { Color.clear.navigationTitle(TitleBarState.shared.title) }
}


extension Track {
    /// The album the playing copy belongs to, when its source names one.
    var albumTitle: String? { best.album.flatMap { $0.isEmpty ? nil : $0 } }
}

// MARK: - Artist

/// An artist's page: their picture and name, Play and Shuffle for their top songs, the top songs, then their albums.
struct ArtistView: View {
    let route: Route
    @Environment(Player.self) private var player
    @State private var artist: ArtistDetail?
    @State private var problem: String?

    var body: some View {
        Group {
            if let artist {
                page(artist)
            } else if let problem {
                ContentUnavailableView("Can't open this artist", systemImage: "music.mic", description: Text(problem))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: route) { await load() }
    }

    private func page(_ artist: ArtistDetail) -> some View {
        let tracks = artist.songs.map(Track.init)
        return List {
            // as the Windows app's (15 Oct): a bigger picture, and the kind of page over the name
            HStack(alignment: .center, spacing: 26) {
                ArtworkView(url: artist.image.flatMap(URL.init(string:)), size: 180, radius: 90)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .selfTestFrame("artist.picture")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Artist").tracking(1.4).textStyle(size: 11, weight: .bold).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(artist.name).tracking(-0.5).textStyle(size: 36, weight: .bold).lineLimit(2).padding(.top, 4)
                    if let listeners = artist.monthlyListeners ?? artist.followers {
                        Text("\(listeners.formatted(.number.notation(.compactName))) \(artist.monthlyListeners != nil ? "monthly listeners" : "followers")")
                            .textStyle(.body).foregroundStyle(.secondary).padding(.top, 6)
                    }
                    PlayShuffleButtons(tracks: tracks).padding(.top, 14)
                }
                Spacer(minLength: 0)
            }
            .pageRow(top: 20, bottom: 18)

            if !tracks.isEmpty {
                Text("Top Songs").textStyle(.title2, weight: .bold).pageRow(top: 8, bottom: 4)
                ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { i, track in
                    SongRow(track: track, queue: tracks, index: i).pageRow(top: 1, bottom: 1, inset: 24)
                }
            }
            if !artist.albums.isEmpty {
                Text("Albums").textStyle(.title2, weight: .bold).pageRow(top: 22, bottom: 4)
                AlbumGrid(albums: artist.albums).pageRow(top: 4, bottom: 24)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollTitle(artist.name)
        .selfTestFrame("artist.page")
    }

    private func load() async {
        problem = nil
        artist = nil                                  // another artist in the same place: not the last one's page meanwhile
        do {
            let ref: ArtistRef
            switch route {
            case .artist(let known): ref = known
            case .artistNamed(let name):
                let found = try await API.searchArtists(name)
                // the same name first (case and accents ignored), else the search's best
                let plain = GeniusNotes.plain(name)
                guard let best = found.first(where: { GeniusNotes.plain($0.name) == plain }) ?? found.first else {
                    problem = "No artist called “\(name)” was found."
                    return
                }
                ref = best.best
            default: return
            }
            artist = try await API.artist(ref)
        } catch {
            problem = error.localizedDescription
        }
    }
}

// MARK: - Album

/// An album's page: the cover, title and artists, Play, Shuffle and Pin to Home, then the songs in order, numbered.
struct AlbumView: View {
    let route: Route
    @Environment(LibraryStore.self) private var library
    @State private var album: AlbumDetail?
    @State private var problem: String?
    @State private var pinning = false

    var body: some View {
        Group {
            if let album {
                page(album)
            } else if let problem {
                ContentUnavailableView("Can't open this album", systemImage: "square.stack", description: Text(problem))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: route) { await load() }
    }

    private func page(_ album: AlbumDetail) -> some View {
        let tracks = album.songs.map(Track.init)
        let ref = AlbumRef(source: album.source, id: album.id, title: album.title, artists: album.artists, year: album.year,
                           image: album.image, songCount: album.songs.count)
        let pinned = library.pinned(ref)
        let minutes = tracks.reduce(0) { $0 + $1.duration } / 60
        return List {
            // as the Windows app's (15 Oct), after Apple Music's album page: a big cover, and the text standing on its
            // bottom edge, the artists in the buttons' colour and the facts in capitals
            HStack(alignment: .bottom, spacing: 28) {
                ArtworkView(url: album.image.flatMap(URL.init(string:)) ?? tracks.first?.image, size: 230, radius: 14)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
                    .selfTestFrame("album.cover")
                VStack(alignment: .leading, spacing: 0) {
                    Text("Album").tracking(1.4).textStyle(size: 11, weight: .bold).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(album.title).tracking(-0.5).textStyle(size: 34, weight: .bold).lineLimit(2).padding(.top, 4)
                    ArtistLinks(artists: album.artists).textStyle(size: 20, weight: .medium).foregroundStyle(.tint).padding(.top, 4)
                    Text(Self.facts(year: album.year, songs: tracks.count, minutes: minutes))
                        .tracking(0.6).textStyle(size: 11.5, weight: .semibold).foregroundStyle(.secondary).padding(.top, 6)
                    HStack(spacing: 10) {
                        PlayShuffleButtons(tracks: tracks)
                        Button {
                            pinning = true
                            Task {
                                if let pinned { await library.unpin(pinned) } else { await library.pin(ref) }
                                pinning = false
                            }
                        } label: {
                            Label(pinned == nil ? "Pin to Home" : "Pinned", systemImage: pinned == nil ? "pin" : "pin.fill")
                                .contentTransition(.symbolEffect(.replace))
                        }
                        .labelStyle(.iconOnly)                         // a round button beside Play and Shuffle; the tooltip says what it does
                        .buttonBorderShape(.circle)
                        .compatGlassButton()
                        .controlSize(.large)
                        .disabled(pinning)
                        .help(pinned == nil ? "Keep this album on Home" : "Remove this album from Home")
                        .selfTestFrame("album.pin")
                    }
                    .padding(.top, 18)
                }
                .selfTestFrame("album.text")
                Spacer(minLength: 0)
            }
            .pageRow(top: 24, bottom: 22)

            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                SongRow(track: track, queue: tracks, index: i, number: i + 1).pageRow(top: 1, bottom: 1, inset: 24)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollTitle(album.title)
        .selfTestFrame("album.page")
    }

    private func load() async {
        problem = nil
        album = nil
        do {
            let ref: AlbumRef
            switch route {
            case .album(let known): ref = known
            case .albumNamed(let title, let artist):
                let found = try await API.searchAlbums("\(title) \(artist)")
                let plain = GeniusNotes.plain(title)
                guard let best = found.first(where: { GeniusNotes.plain($0.title) == plain }) ?? found.first else {
                    problem = "No album called “\(title)” was found."
                    return
                }
                ref = best.best
            default: return
            }
            album = try await API.album(ref)
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The line under the artists, in capitals (15 Oct, as in the Windows app): "2024 · 12 SONGS · 37 MIN"; an
    /// unknown year or length is left out.
    static func facts(year: Int?, songs: Int, minutes: Int) -> String {
        ([year.map(String.init), SongListView.count(songs), minutes > 0 ? "\(minutes) min" : nil] as [String?])
            .compactMap { $0 }.joined(separator: " · ").uppercased()
    }
}

// MARK: - Pieces

/// Play and Shuffle, as on Liked Songs.
struct PlayShuffleButtons: View {
    let tracks: [Track]
    @Environment(Player.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            Button { player.playInOrder(tracks) } label: { Label("Play", systemImage: "play.fill") }
                .compatGlassButton(prominent: true)
            Button { player.shufflePlay(tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
                .compatGlassButton()
        }
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }
}

/// Artist names, each one a link to that artist's page, separated by commas.
struct ArtistLinks: View {
    let artists: [String]
    var close: (() -> Void)? = nil            // Now Playing: closes itself before the page opens

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(artists.enumerated()), id: \.offset) { i, name in
                Button(name) {
                    close?()
                    Navigator.shared.open(.artistNamed(name))
                }
                .buttonStyle(.quiet)
                .help("Go to \(name)")
                if i < artists.count - 1 { Text(", ") }
            }
        }
        .lineLimit(1)
    }
}

/// Albums as a grid of covers; a click opens the album.
struct AlbumGrid: View {
    let albums: [AlbumRef]
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)

    var body: some View {
        FlowLayout(spacing: 20, lineSpacing: 26) {           // as Home's playlists: the shelf's gap, not a stretched column
            ForEach(albums, id: \.self) { AlbumCard(album: $0, side: cardSize) }
        }
    }
}

/// Search's Albums under All: one row of as many as fit, and See All (the Albums filter) when some do not. Not a row
/// that scrolls sideways: inside the results list it caught every scroll that started over it, so the results could
/// not be scrolled from there.
struct AlbumShelf: View {
    let albums: [AlbumRef]
    let seeAll: () -> Void
    @AppStorage("cardSize") private var cardSize = Double(Look.cardSize)
    @State private var width: CGFloat = 0

    var body: some View {
        let side = cardSize * 0.85
        let fit = max(1, Int((width + 20) / (side + 20)))
        VStack(alignment: .leading, spacing: 6) {
            ShelfHeader(title: "Albums", more: albums.count > fit, seeAll: seeAll)
            HStack(alignment: .top, spacing: 20) {
                ForEach(albums.prefix(fit), id: \.self) { AlbumCard(album: $0, side: side) }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A shelf's title, with See All when the row does not show every item.
struct ShelfHeader: View {
    let title: String
    let more: Bool
    let seeAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).textStyle(.title3, weight: .bold)
            Spacer()
            if more {
                Button("See All", action: seeAll).buttonStyle(.quiet).foregroundStyle(.secondary)
            }
        }
    }
}

/// An album's cover, title, and year or artist. A click opens it.
struct AlbumCard: View {
    let album: AlbumRef
    let side: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            TiltCard(side: side) { ArtworkView(url: album.image.flatMap(URL.init(string:)), size: side, radius: 12) }
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title).textStyle(.callout, weight: .medium).lineLimit(1)
                Text(album.year.map(String.init) ?? album.artists.joined(separator: ", "))
                    .textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: side, alignment: .leading)
        }
        .contentShape(.rect)
        .onTapGesture { Navigator.shared.open(.album(album)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(album.title)")
    }
}

/// Search's filter: capsules in a row, the chosen one filled.
struct FilterCapsules: View {
    @Binding var selection: SearchFilter

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SearchFilter.allCases) { filter in
                let on = filter == selection
                Button { selection = filter } label: {
                    Text(filter.title)
                        .textStyle(.callout, weight: .medium)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .foregroundStyle(on ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        .background(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.07)), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.2), value: selection)
        .selfTestFrame("search.filters")
    }
}

/// Artists as a grid of round pictures (Search › Artists).
struct ArtistGrid: View {
    let artists: [SearchArtist]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 18, alignment: .top)], alignment: .leading, spacing: 22) {
            ForEach(artists, id: \.best) { ArtistBubble(artist: $0) }
        }
    }
}

/// An artist's round picture with the name under it; a click opens the artist.
struct ArtistBubble: View {
    let artist: SearchArtist

    var body: some View {
        VStack(spacing: 8) {
            ArtworkView(url: (artist.image ?? artist.best.image).flatMap(URL.init(string:)), size: 96, radius: 48)
            Text(artist.name).textStyle(.callout, weight: .medium).lineLimit(1).frame(width: 110)
        }
        .contentShape(.rect)
        .onTapGesture { Navigator.shared.open(.artist(artist.best)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Open \(artist.name)")
    }
}

/// Search's Artists under All: one row of round pictures, as many as fit, and See All (the Artists filter) when some
/// do not (see AlbumShelf: a row that scrolled sideways caught the results' scrolling).
struct ArtistShelf: View {
    let artists: [SearchArtist]
    let seeAll: () -> Void
    @State private var width: CGFloat = 0

    var body: some View {
        let fit = max(1, Int((width + 22) / (110 + 22)))
        VStack(alignment: .leading, spacing: 6) {
            ShelfHeader(title: "Artists", more: artists.count > fit, seeAll: seeAll)
            HStack(alignment: .top, spacing: 22) {
                ForEach(artists.prefix(fit), id: \.best) { ArtistBubble(artist: $0) }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

extension View {
    /// A row of a page built as a List: no separator, no background, the page's margins.
    func browseRow(top: CGFloat, bottom: CGFloat, inset: CGFloat = 24) -> some View {
        listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: top, leading: inset, bottom: bottom, trailing: inset))
    }

    /// A row of an artist, album or playlist page or a song list (15 Oct, as in the Windows app): drawn 32 pt from the
    /// page's edges (song rows 24: their own 8 pt padding brings the cover to the same line), inside the page column.
    /// Each row keeps to the column, not the List: a List narrower than the window would not scroll from its sides, and
    /// its scroller would stand in the middle of a wide window. The row reaches into the List's own margin, so both
    /// the inset and the column measure from the page's edges.
    func pageRow(top: CGFloat, bottom: CGFloat, inset: CGFloat = 32) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .pageColumn()
            .padding(.horizontal, -listOwnMargin)
            .browseRow(top: top, bottom: bottom, inset: 0)
    }
}

/// What a List keeps on each side of every row on its own, whatever the row's insets: rows inset 32 were drawn 40 pt
/// from the List's edge (measured on macOS 26, 15 Oct). So browseRow's 24 draws at 32.
private let listOwnMargin: CGFloat = 8
