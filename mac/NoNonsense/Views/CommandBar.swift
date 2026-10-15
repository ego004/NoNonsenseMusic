import SwiftUI

// The command bar (the redesign, 15 Oct): a field at the leading edge of the toolbar, "Search, or type a command".
// Typing finds the commands whose name starts that way (play, skip, like, lyrics, a jam, a playlist, a page) and songs;
// Return runs the chosen row. ⌘K, ⌘F and / put the keyboard in it from anywhere; Esc leaves. The field lives in the
// toolbar and its list over the window, so the two share CommandBarState.

/// One thing the command bar can do: a name that follows the moment (Play or Pause, Like or Remove from Liked Songs),
/// its SF Symbol, what it acts on, its key outside the bar, and whether it is offered before anything is typed.
struct Command {
    let label: String
    let symbol: String
    /// What it acts on: the song, the artist, the album, "Playlist".
    var detail: String? = nil
    /// Its key outside the bar, shown in a chip: "Space", "⌘→", "L".
    var keys: String? = nil
    /// Offered with nothing typed.
    var suggested = false
    let run: () -> Void

    /// Whether every word typed starts a word of `label`, in any order: "lyr", "go art" and "ball" find Lyrics, Go to
    /// Artist and a playlist named Ballin; "rtist" and "go x" find nothing. The Windows app's rule, word for word.
    static func matches(_ query: String, label: String) -> Bool {
        let names = words(label)
        return words(query).allSatisfy { typed in names.contains { $0.hasPrefix(typed) } }
    }

    /// Lowercased words, split at spaces, dashes, commas, full stops, colons, brackets, slashes, & and +.
    private static func words(_ text: String) -> [Substring] {
        text.lowercased().split { $0.isWhitespace || "-–—,.:()/&+".contains($0) }
    }
}

/// A row of the list: a command, a song found (with its place among the songs found), or the Search page with every
/// result for these words.
enum CommandEntry {
    case command(Command)
    case song(Track, Int)
    case all(String)

    var title: String {
        switch self {
        case .command(let command): command.label
        case .song(let track, _): track.title
        case .all(let words): "All results for “\(words)”"
        }
    }
    var detail: String? { switch self { case .command(let command): command.detail; case .song, .all: nil } }
    var keys: String? { switch self { case .command(let command): command.keys; case .song, .all: nil } }
    var symbol: String { switch self { case .command(let command): command.symbol; case .song: "music.note"; case .all: "magnifyingglass" } }
    var song: Track? { switch self { case .song(let track, _): track; case .command, .all: nil } }
    var isAll: Bool { switch self { case .all: true; case .command, .song: false } }
}

/// What the commands reach beyond the stores, given by the window (RootView): its screens, its Search page, Settings.
struct CommandContext {
    let player: Player
    let library: LibraryStore
    let downloads: DownloadStore
    /// A screen or a playlist, any artist or album page over it closed.
    let open: (Destination) -> Void
    /// The Search page, searching these words.
    let search: (String) -> Void
    /// The Settings window.
    let settings: () -> Void
}

/// The command bar's state, shared by its field (in the toolbar), its list (over the window) and the keys that call it
/// (⌘K and ⌘F in RootView, / in Player's key monitor). Nothing in it changes while the bar is idle.
@Observable
final class CommandBarState {
    static let shared = CommandBarState()

    /// What is typed. Each change looks for songs anew (`typed`).
    var query = "" { didSet { if query != oldValue { typed() } } }
    /// The songs found for what is typed, at most 5. They stay while newer words are looked for.
    private(set) var songs: [Track] = []
    /// A song search is under way: "Searching…" until songs come.
    private(set) var searching = false
    /// The row ↑ ↓ and the pointer chose: Return runs it.
    var chosen = 0
    /// The field has the keyboard, so the list is open.
    private(set) var open = false
    /// Asks to the field, which owns the keyboard focus: take it (with what is typed selected), or let it go.
    private(set) var focusRequests = 0
    private(set) var leaveRequests = 0
    /// The detail column's width (RootView measures it): the field takes what the toolbar can spare of it.
    private(set) var columnWidth: CGFloat = 0

    /// What the commands reach: RootView gives it.
    @ObservationIgnored var context: CommandContext?
    /// The field is in the toolbar (it is not on the Search page): / is the bar's only then.
    @ObservationIgnored var onScreen = false
    /// The field's capsule as an AppKit view (FieldAnchor): where the list goes, and where a click lands.
    @ObservationIgnored weak var fieldView: NSView?
    /// The list's frame in the window, in SwiftUI's global points, while it is open.
    @ObservationIgnored var listFrame: CGRect = .zero
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private var asked = 0                  // the newest search: an older answer that comes late is dropped
    @ObservationIgnored private var clickMonitor: Any?

    // MARK: - keyboard focus

    /// ⌘K, ⌘F and /: the field takes the keyboard, what is typed selected.
    func summon() { focusRequests += 1 }

    /// The field lets go of the keyboard (a click outside); what is typed stays. The list closes at once, not only once
    /// the field's focus has followed.
    func leave() {
        leaveRequests += 1
        focusChanged(false)
    }

    /// Esc, and every run: what is typed goes, and the field lets go of the keyboard.
    func close() {
        query = ""
        leave()
    }

    /// The field took the keyboard or let it go: the list opens or closes, its first row chosen.
    func focusChanged(_ focused: Bool) {
        if chosen != 0 { chosen = 0 }
        guard focused != open else { return }
        open = focused
        watchClicks(focused)
    }

    /// After a summon, once SwiftUI has had its turn: the field has the keyboard, what is typed selected, and the list
    /// is open. SwiftUI's focus did not reach the toolbar's field in a window that was not key (CI, 15 Oct); AppKit's
    /// first responder does, and SwiftUI's focus follows it as it follows a click.
    func takeKeyboard() {
        guard let field = textField, let window = field.window else { return }
        if field.currentEditor() == nil { _ = window.makeFirstResponder(field) }
        guard let editor = field.currentEditor() else { return }
        editor.selectAll(nil)
        focusChanged(true)
    }

    /// After a leave: the field no longer has the keyboard, whether or not SwiftUI's focus got there first.
    func letGo() {
        guard let field = textField, field.currentEditor() != nil else { return }
        _ = field.window?.makeFirstResponder(nil)
    }

    /// The field's own AppKit text field: the one in the capsule FieldAnchor marks, among the toolbar item's views.
    private var textField: NSTextField? {
        guard let anchor = fieldView else { return nil }
        let capsule = anchor.convert(anchor.bounds, to: nil)
        var host = anchor.superview
        while let view = host {
            if let field = Self.editableField(in: view, within: capsule) { return field }
            host = view.superview
        }
        return nil
    }

    private static func editableField(in view: NSView, within capsule: CGRect) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, field.isEditable, capsule.intersects(field.convert(field.bounds, to: nil)) { return field }
            if let found = editableField(in: sub, within: capsule) { return found }
        }
        return nil
    }

    // MARK: - how wide the field is

    /// The detail column was laid out at this width.
    func columnResized(_ width: CGFloat) {
        let rounded = width.rounded()
        if rounded != columnWidth { columnWidth = rounded }
    }

    /// The field's width: what the toolbar can spare, 180…560. The toolbar never shrinks a field below the width it
    /// asks for: at 560 it moved Jam and the bell into its » menu at 1024 pt, and the field too at 900 (CI, 15 Oct). So
    /// the field asks for the column less what the rest needs: Jam, the bell and the toolbar's margins, Back while a page
    /// is open, LIVE in a jam, and the window's buttons and the sidebar's when the sidebar is hidden.
    var fieldWidth: CGFloat {
        var spare = columnWidth - 340
        if !Navigator.shared.path.isEmpty { spare -= 44 }
        if JamSession.shared.inJam { spare -= 56 }
        if let window = fieldView?.window, columnWidth >= window.frame.width - 1 { spare -= 140 }
        return min(560, max(180, spare))
    }

    // MARK: - what the list holds

    /// What is typed changed: the first row is chosen again, and songs are looked for once typing pauses (250 ms; two
    /// letters or more). The search before is cancelled; an answer to older words that still comes is dropped. The songs
    /// found stay until the new answer, which replaces them.
    private func typed() {
        search?.cancel()
        asked += 1
        if chosen != 0 { chosen = 0 }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 2 else {
            if !songs.isEmpty { songs = [] }
            if searching { searching = false }
            return
        }
        if !searching { searching = true }
        let mine = asked
        search = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // the server's search, as Search asks it (songs only): no server now gives no songs, and the commands still work
            let found = (try? await API.search(words, filter: SearchFilter.songs.rawValue))?.songs.prefix(5).map(Track.init) ?? []
            guard mine == asked else { return }
            songs = found
            searching = false
        }
    }

    /// Everything the bar can do now, in the list's order: for the song playing (if any), then the jam, a new playlist,
    /// the window's places, Settings and your playlists. Read in the list's body, so the list follows all of it.
    func commands() -> [Command] {
        guard let context else { return [] }
        let player = context.player, library = context.library, downloads = context.downloads
        var all: [Command] = []
        if let song = player.current {
            let liked = library.isLiked(song)
            all += [
                Command(label: player.isPlaying ? "Pause" : "Play", symbol: player.isPlaying ? "pause" : "play", detail: song.title,
                        keys: "Space", suggested: true) { player.togglePlayPause() },
                Command(label: "Next Song", symbol: "forward.end", keys: "⌘→", suggested: true) { player.next() },
                Command(label: "Previous Song", symbol: "backward.end", keys: "⌘←") { player.previous() },
                Command(label: liked ? "Remove from Liked Songs" : "Like", symbol: liked ? "heart.fill" : "heart", detail: song.title,
                        keys: "L", suggested: true) { Task { await library.toggleLike(song) } },
                Command(label: "Lyrics", symbol: "quote.bubble", suggested: true) { Self.nowPlaying(.lyrics, player) },
                Command(label: "Up Next", symbol: "list.bullet", suggested: true) { Self.nowPlaying(.upNext, player) },
                Command(label: "Now Playing", symbol: "arrow.up.left.and.arrow.down.right") { Self.nowPlaying(.none, player) },
                Command(label: player.isShuffled ? "Shuffle Off" : "Shuffle On", symbol: "shuffle") { player.toggleShuffle() },
                // what pressing it does: the next of off → all → one
                Command(label: "Repeat \(player.repeatMode.next.label)", symbol: "repeat") { player.cycleRepeat() },
                Command(label: player.isMuted ? "Unmute" : "Mute", symbol: player.isMuted ? "speaker.slash" : "speaker.wave.2",
                        keys: "M") { player.toggleMute() },
            ]
            if let artist = song.artists.first {
                all.append(Command(label: "Go to Artist", symbol: "person", detail: artist) { Navigator.shared.open(.artistNamed(artist)) })
            }
            if let album = song.albumTitle {
                all.append(Command(label: "Go to Album", symbol: "square.stack", detail: album) {
                    Navigator.shared.open(.albumNamed(title: album, artist: song.artists.first ?? ""))
                })
            }
            if downloads.available {
                if downloads.isDownloaded(song) {
                    all.append(Command(label: "Show in Finder", symbol: "folder", detail: song.title) { downloads.revealInFinder(song) })
                } else {
                    all.append(Command(label: "Download", symbol: "arrow.down.circle", detail: song.title) { Task { await downloads.download(song) } })
                }
            }
        }
        let idle = player.current == nil
        all.append(Command(label: JamSession.shared.inJam ? "Jam" : "Start or Join a Jam", symbol: "person.2.wave.2", suggested: true) {
            JamPanelState.shared.shown = true                       // the jam's popover, under its toolbar button
        })
        all.append(Command(label: "New Playlist…", symbol: "plus", suggested: idle) { library.newPlaylistRequest = .init(track: nil) })
        for item in [SidebarItem.home, .library, .liked, .recent, .downloads, .friends] where item != .downloads || downloads.available {
            all.append(Command(label: item.title, symbol: item.symbol, suggested: idle && (item == .library || item == .liked)) {
                context.open(.section(item))
            })
        }
        all.append(Command(label: "Settings", symbol: "gearshape") { context.settings() })
        all += library.playlists.map { playlist in
            Command(label: playlist.name, symbol: "music.note.list", detail: "Playlist") { context.open(.playlist(playlist.id)) }
        }
        return all
    }

    /// The list's rows: with nothing typed, the suggested commands (at most 7); else up to 5 matching commands, the
    /// songs found, and every result.
    func entries() -> [CommandEntry] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = commands()
        guard !words.isEmpty else { return available.filter(\.suggested).prefix(7).map(CommandEntry.command) }
        let matching = available.filter { Command.matches(words, label: $0.label) }.prefix(5).map(CommandEntry.command)
        let found = songs.enumerated().map { CommandEntry.song($0.element, $0.offset) }
        return matching + found + [CommandEntry.all(words)]
    }

    /// The chosen row among `count`: the first when the list has shrunk under it.
    func chosenRow(of count: Int) -> Int { chosen < count ? chosen : 0 }

    // MARK: - running

    /// The field's keys, heard before the field (which would move its cursor on ↑ ↓).
    func pressed(_ press: KeyPress) -> KeyPress.Result {
        handle(press.key, shift: press.modifiers.contains(.shift), repeated: press.phase == .repeat)
        return .handled
    }

    /// ↑ ↓ choose, round at either end; Return (or the keypad's Enter) runs the chosen row, once per press (⇧Return: a
    /// song goes to Up Next instead); Esc empties the field and leaves it.
    func handle(_ key: KeyEquivalent, shift: Bool = false, repeated: Bool = false) {
        let rows = entries()
        let count = rows.count, row = chosenRow(of: count)
        if key == .downArrow || key == .upArrow {
            if count > 0 { chosen = (row + (key == .downArrow ? 1 : count - 1)) % count }
        } else if key == .escape {
            close()
        } else if !repeated, count > 0 {
            run(rows[row], toUpNext: shift)
        }
    }

    /// Runs a row. The field empties and lets go first; then the command runs, or the song plays with the other songs
    /// found after it (`toUpNext`: it goes to Up Next instead), or Search opens with every result.
    func run(_ entry: CommandEntry, toUpNext: Bool = false) {
        let found = songs
        close()
        switch entry {
        case .command(let command):
            command.run()
        case .song(let song, let index):
            if toUpNext { context?.player.addToQueue(song) } else { context?.player.play(found, startAt: index) }
        case .all(let words):
            context?.search(words)
        }
    }

    /// Now Playing with this panel beside the song, as the player bar's buttons open it.
    private static func nowPlaying(_ panel: NowPlayingPanel, _ player: Player) {
        UserDefaults.standard.set(panel.rawValue, forKey: "nowPlayingPanel")       // its @AppStorage
        player.showNowPlaying = true
    }

    // MARK: - where the field is

    /// The window the list is drawn in: the field's own, except in full screen, where macOS puts the toolbar in a
    /// window of its own over the main one.
    private var contentWindow: NSWindow? {
        guard let own = fieldView?.window else { return nil }
        if own.styleMask.contains(.titled) { return own }
        return NSApp.windows.first { $0.styleMask.contains(.fullScreen) && $0.frame.intersects(own.frame) }
    }

    /// The field's frame in that window, in SwiftUI's global points (top-left origin), where the list hangs from.
    var fieldFrame: CGRect? {
        guard let view = fieldView, let own = view.window, let window = contentWindow, let content = window.contentView else { return nil }
        let r = window.convertFromScreen(own.convertToScreen(view.convert(view.bounds, to: nil)))
        return CGRect(x: r.minX, y: content.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// While the list is open, a click anywhere else in the window takes the keyboard from the field and the list
    /// closes; the click goes on to what it was for. No monitor while the bar is idle.
    private func watchClicks(_ on: Bool) {
        if on, clickMonitor == nil {
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clicked(event)
                }
                return event
            }
        } else if !on, let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func clicked(_ event: NSEvent) {
        // a click in another window (Settings) is that window's own business
        guard let window = contentWindow, let content = window.contentView, let target = event.window,
              target === window || target === fieldView?.window else { return }
        let p = window.convertPoint(fromScreen: target.convertPoint(toScreen: event.locationInWindow))
        let point = CGPoint(x: p.x, y: content.bounds.height - p.y)
        if fieldFrame?.contains(point) != true, !listFrame.contains(point) { leave() }
    }
}

// MARK: - the field

/// The command bar's field, at the leading edge of the toolbar: a capsule with a magnifying glass, "Search, or type a
/// command", and ⌘K in a chip while it does not have the keyboard. It owns the keyboard focus; its list is
/// CommandListLayer, over the window.
struct CommandField: View {
    @FocusState private var focused: Bool
    private var bar: CommandBarState { .shared }
    /// The keypad's Enter, which runs the chosen row as Return does.
    private static let enter = KeyEquivalent("\u{03}")

    var body: some View {
        @Bindable var bar = bar
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search, or type a command", text: $bar.query)
                .textFieldStyle(.plain)
                .textStyle(.body)
                .focused($focused)
                // ↑ ↓ Return Esc are the list's
                .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape, Self.enter]) { bar.pressed($0) }
            if !focused { KeyChip(keys: "⌘K") }
        }
        .padding(.leading, 12)
        .padding(.trailing, focused ? 12 : 8)
        .frame(width: bar.fieldWidth, height: 32)                       // what the toolbar can spare (fieldWidth)
        .compatGlass(in: .capsule, interactive: true)
        .overlay {
            if focused { Capsule().strokeBorder(.tint, lineWidth: 1.5).allowsHitTesting(false) }
        }
        .background(FieldAnchor())
        .onChange(of: focused) { _, now in bar.focusChanged(now) }
        // ⌘K, ⌘F and /: the keyboard, and what is typed selected so the next key replaces it
        .onChange(of: bar.focusRequests) {
            focused = true
            Task { CommandBarState.shared.takeKeyboard() }
        }
        .onChange(of: bar.leaveRequests) {
            focused = false
            Task { CommandBarState.shared.letGo() }
        }
        .onAppear { bar.onScreen = true }
        .onDisappear {
            bar.onScreen = false
            bar.focusChanged(false)                                      // gone (the Search page opened): no list left open
        }
    }
}

/// The field's capsule as an AppKit view, so the bar knows where the field is in the window: the toolbar hosts its
/// items apart from the window's content, so a SwiftUI frame read there need not be in the window's points. Takes no
/// clicks.
private struct FieldAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = Anchor()
        CommandBarState.shared.fieldView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class Anchor: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// A key or two as the keyboard shows them, in a thin rounded frame: ⌘K, Space, L.
private struct KeyChip: View {
    let keys: String

    var body: some View {
        Text(keys)
            .textStyle(size: 11, weight: .semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.primary.opacity(0.16)) }
    }
}

// MARK: - the list

/// Where the list goes: over the window, not in a popover (which would take the keyboard from the field), its left edge
/// under the field's, 8 pt below it, at least 440 wide. Nothing at all while the bar is closed.
struct CommandListLayer: View {
    private var bar: CommandBarState { .shared }

    var body: some View {
        if bar.open {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .global).origin
                // read again when the window resizes (this closure runs then): the field moves with the toolbar
                if let field = bar.fieldFrame {
                    CommandList(width: max(field.width, 440), maxHeight: max(200, min(560, proxy.size.height - 140)))
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bar.listFrame = $0 }
                        .selfTestFrame("commandBar.list")
                        .padding(.leading, field.minX - origin.x)
                        .padding(.top, field.maxY + 8 - origin.y)
                }
            }
        }
    }
}

/// The list: the commands and songs for what is typed, in a glass card. Built only while open, and while open it
/// follows the moment: Play becomes Pause, Like becomes Remove from Liked Songs, songs arrive.
private struct CommandList: View {
    let width: CGFloat
    let maxHeight: CGFloat
    private var bar: CommandBarState { .shared }

    /// A line of the list: a heading, "Searching…", or a row (with its place among the rows).
    enum Line {
        case heading(String), searching, row(Int, CommandEntry)

        var text: String {
            switch self {
            case .heading(let text): text
            case .searching: "Searching…"
            case .row(_, let entry): entry.title
            }
        }
    }

    var body: some View {
        let entries = bar.entries()
        let shown = lines(for: entries)
        let chosen = bar.chosenRow(of: entries.count)
        VStack(alignment: .leading, spacing: 0) {
            // the rows as they are while they fit; scrolling when they do not, the hint still in sight
            ViewThatFits(in: .vertical) {
                rows(shown, chosen: chosen)
                ScrollView { rows(shown, chosen: chosen) }
            }
            Text(hint)
                .textStyle(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(EdgeInsets(top: 8, leading: 14, bottom: 6, trailing: 14))
        }
        .padding(.vertical, 6)
        .frame(width: width, alignment: .leading)
        .frame(maxHeight: maxHeight)
        .compatGlass(in: .rect(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
        #if DEBUG
        .onChange(of: shown.map(\.text), initial: true) { _, now in SelfTest.commandRows = now }
        .onChange(of: hint, initial: true) { _, now in SelfTest.commandHint = now }
        #endif
    }

    /// SUGGESTED (nothing typed) or ACTIONS over the commands, SONGS over the songs, or SONGS and "Searching…" just
    /// above every result while none have come.
    private func lines(for entries: [CommandEntry]) -> [Line] {
        let typed = !bar.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var lines: [Line] = []
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .command where index == 0: lines.append(.heading(typed ? "ACTIONS" : "SUGGESTED"))
            case .song(_, 0): lines.append(.heading("SONGS"))
            case .all where bar.searching && bar.songs.isEmpty: lines += [.heading("SONGS"), .searching]
            default: break
            }
            lines.append(.row(index, entry))
        }
        return lines
    }

    /// The keys that work here and now.
    private var hint: String {
        if bar.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Space play or pause · ← → seek · ⌘ ← → skip · L like · M mute"
        }
        return bar.songs.isEmpty ? "↑ ↓ choose · Return run · Esc close" : "↑ ↓ choose · Return play · ⇧Return add to Up Next · Esc close"
    }

    private func rows(_ lines: [Line], chosen: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                switch line {
                case .heading(let text):
                    Text(text)
                        .textStyle(size: 11.5, weight: .bold)
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 10, leading: 14, bottom: 4, trailing: 14))
                case .searching:
                    Text("Searching…")
                        .textStyle(size: 13)
                        .foregroundStyle(.secondary)
                        .padding(EdgeInsets(top: 6, leading: 14, bottom: 10, trailing: 14))
                case .row(let index, let entry):
                    CommandRow(entry: entry, chosen: index == chosen) {
                        if bar.chosen != index { bar.chosen = index }    // the pointer chooses, as ↑ ↓ do
                    } run: {
                        bar.run(entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One row: a song's cover or the command's symbol in a soft square, the name (and what it acts on), the key chip.
/// The chosen row has a soft fill; the pointer over a row chooses it (no other hover look, nothing animated).
private struct CommandRow: View {
    let entry: CommandEntry
    let chosen: Bool
    let hover: () -> Void
    let run: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            picture.padding(.trailing, 12)
            words.frame(maxWidth: .infinity, alignment: .leading)
            if let keys = entry.keys { KeyChip(keys: keys).padding(.leading, 10) }
            if entry.isAll { Image(systemName: "arrow.right").textStyle(size: 13).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background {
            if chosen { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.08)) }
        }
        .contentShape(.rect)
        .onHover { if $0 { hover() } }
        .onTapGesture(perform: run)
        .padding(.horizontal, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .selfTestFrame("commandBar.row:\(entry.title)")
    }

    @ViewBuilder private var picture: some View {
        if let song = entry.song {
            ArtworkView(url: song.image, size: 34, radius: 6)
        } else {
            Image(systemName: entry.symbol)
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.8))
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder private var words: some View {
        if let song = entry.song {
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).textStyle(size: 14, weight: .semibold).lineLimit(1)
                Text(song.artistLine).textStyle(size: 12.5).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.title).textStyle(size: 14, weight: .semibold).lineLimit(1).layoutPriority(1)
                if let detail = entry.detail {
                    Text(detail).textStyle(size: 12.5).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
