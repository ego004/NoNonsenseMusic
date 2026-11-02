import SwiftUI

/// A playlist's own menu: rename, share, make public or private, delete (yours); leave (shared with you); unpin (an album).
struct PlaylistMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistSummary
    @State private var renaming = false
    @State private var sharing = false
    @State private var deleting = false
    @State private var name = ""
    @State private var username = ""

    var body: some View {
        // the library's copy has the latest name and public flag; this screen's own was made when it opened
        let current = library.playlists.first { $0.id == playlist.id } ?? playlist
        Menu {
            if current.isAlbum {
                Button(role: .destructive) { Task { await library.unpin(current); dismiss() } } label: {
                    Label("Unpin Album", systemImage: "pin.slash")
                }
            } else if current.isOwner {
                Button { name = current.name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                Button { username = ""; sharing = true } label: { Label("Share…", systemImage: "person.badge.plus") }
                Button { Task { await library.setPublic(current, !current.isPublic) } } label: {
                    Label(current.isPublic ? "Make Private" : "Make Public", systemImage: current.isPublic ? "lock" : "globe")
                }
                Divider()
                Button(role: .destructive) { deleting = true } label: { Label("Delete Playlist", systemImage: "trash") }
            } else {
                Button(role: .destructive) { Task { await library.leave(current); dismiss() } } label: {
                    Label("Leave Playlist", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Playlist options")
        .alert("Rename Playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                Task { if let problem = await library.renamePlaylist(current, to: name) { library.notify(problem, symbol: "exclamationmark.triangle.fill") } }
            }
        }
        .alert("Share “\(current.name)”", isPresented: $sharing) {
            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Can View") { share("viewer", current) }
            Button("Can Make Changes") { share("editor", current) }
        } message: {
            Text("They need an account on this server.")
        }
        .confirmationDialog("Delete “\(current.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await library.deletePlaylist(current); dismiss() } }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func share(_ role: String, _ playlist: PlaylistSummary) {
        let who = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else { return }
        Task { if let problem = await library.share(playlist, with: who, role: role) { library.notify(problem, symbol: "exclamationmark.triangle.fill") } }
    }
}

/// "New Playlist": asks for a name, then makes it (and puts `adding` in it, when a song's menu asked).
private struct NewPlaylistAlert: ViewModifier {
    @Environment(LibraryStore.self) private var library
    @Binding var shown: Bool
    let adding: Track?
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New Playlist", isPresented: $shown) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { name = "" }
            Button("Create") {
                let chosen = name.trimmingCharacters(in: .whitespacesAndNewlines)
                name = ""
                guard !chosen.isEmpty else { return }
                Task { if let problem = await library.createPlaylist(named: chosen, adding: adding) { library.notify(problem, symbol: "exclamationmark.triangle.fill") } }
            }
        }
    }
}

extension View {
    func newPlaylistAlert(_ shown: Binding<Bool>, adding: Track? = nil) -> some View {
        modifier(NewPlaylistAlert(shown: shown, adding: adding))
    }
}
