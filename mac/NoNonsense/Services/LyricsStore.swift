import Foundation
import Observation

/// Lyrics for songs (MUS-12), from the server's POST /lyrics. The server keeps every answer in its own table, so a
/// song asked for before answers in a few milliseconds; the first time takes ~0.7 s (LRCLIB) to ~2 s (YouTube Music).
/// Here they are kept in memory for the session, by song. Downloaded songs keep theirs on disk beside the audio
/// (DownloadStore), so they show offline too.
@Observable
final class LyricsStore {
    enum State: Equatable {
        case loading
        case found(Lyrics)        // `lines` may be empty: nobody has lyrics for this song
        case unreachable          // the server could not be asked (no network, or it is not running)
    }

    /// By Track.id. No entry: never asked.
    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let downloads: DownloadStore

    init(downloads: DownloadStore) {
        self.downloads = downloads
    }

    func state(for track: Track) -> State? { states[track.id] }

    /// Genius notes by Track.id (Settings › Lyrics › Genius notes, off by default). No entry: not asked, or not found.
    private(set) var notes: [String: GeniusNotes] = [:]
    @ObservationIgnored private var notesAsked: Set<String> = []
    static var geniusOn: Bool { UserDefaults.standard.bool(forKey: "geniusNotes") }

    /// Asks for this song's Genius notes once, beside its lyrics, when the setting is on. A failure is asked again on
    /// the song's next start. Nothing is shown until they arrive: the lyrics never wait for them.
    func fetchNotes(_ track: Track) {
        guard Self.geniusOn, !notesAsked.contains(track.id) else { return }
        notesAsked.insert(track.id)
        Task {
            do { notes[track.id] = try await API.genius(for: track) } catch { notesAsked.remove(track.id) }
        }
    }

    /// Asks for this song's lyrics, once: a song already found, or being asked for, is not asked again. A song the
    /// server could not be asked about is asked again (the panel's Retry). A downloaded song answers from its file.
    func fetch(_ track: Track) {
        fetchNotes(track)
        if case .found = states[track.id] { return }
        guard running[track.id] == nil else { return }
        if let saved = downloads.lyrics(for: track) {
            states[track.id] = .found(saved)
            return
        }
        states[track.id] = .loading
        running[track.id] = Task {
            defer { running[track.id] = nil }
            do {
                states[track.id] = .found(try await API.lyrics(for: track))
            } catch {
                states[track.id] = .unreachable
            }
        }
    }

    /// A song was just downloaded: keep its lyrics beside the file (asking the server if this session has not).
    func keep(for track: Track) async {
        if case .found(let found) = states[track.id] {
            downloads.saveLyrics(found, for: track)
        } else if let found = try? await API.lyrics(for: track) {
            states[track.id] = .found(found)
            downloads.saveLyrics(found, for: track)
        }
    }

    #if DEBUG
    /// Self-tests: forget what this session knows about a song, so the next fetch asks again (or reads the file).
    func forget(_ track: Track) { states[track.id] = nil }
    /// Self-tests: lyrics and notes for a made-up song, as if the server had answered.
    func give(_ found: Lyrics, notes given: GeniusNotes?, for track: Track) {
        states[track.id] = .found(found)
        notes[track.id] = given
        notesAsked.insert(track.id)
    }
    #endif
}
