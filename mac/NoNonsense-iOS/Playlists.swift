import SwiftUI
import UniformTypeIdentifiers

/// A playlist's own menu: rename, share, make public or private, delete (yours); leave (shared with you); unpin (an album).
struct PlaylistMenu: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistSummary
    let tracks: [Track]
    @State private var renaming = false
    @State private var sharing = false
    @State private var deleting = false
    @State private var leaving = false
    @State private var choosingFiles = false
    @State private var askingLink = false
    @State private var link = ""
    @State private var name = ""

    var body: some View {
        // the library's copy has the latest name and public flag; this screen's own was made when it opened
        let current = library.playlists.first { $0.id == playlist.id } ?? playlist
        Menu {
            Button { Task { await downloads.download(all: tracks, name: current.name) } } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(tracks.isEmpty)
            if current.canEdit {
                // songs from Spotify (Exportify, Spotify's data download) or YouTube (Google Takeout, a playlist link)
                Menu {
                    Button { choosingFiles = true } label: { Label("Songs from Files…", systemImage: "doc") }
                    Button { askingLink = true } label: { Label("Songs from a YouTube Playlist…", systemImage: "link") }
                } label: {
                    Label(SpotifyImporter.shared.running ? "Importing…" : "Import", systemImage: "square.and.arrow.down")
                }
                .disabled(SpotifyImporter.shared.running)
            }
            Divider()
            if current.isAlbum {
                Button(role: .destructive) { Task { await library.unpin(current); dismiss() } } label: {
                    Label("Unpin Album", systemImage: "pin.slash")
                }
            } else if current.isOwner {
                Button { name = current.name; renaming = true } label: { Label("Rename…", systemImage: "pencil") }
                Button { sharing = true } label: { Label("Share…", systemImage: "person.badge.plus") }
                Button { Task { await library.setPublic(current, !current.isPublic) } } label: {
                    Label(current.isPublic ? "Make Private" : "Make Public", systemImage: current.isPublic ? "lock" : "globe")
                }
                Divider()
                Button(role: .destructive) { deleting = true } label: { Label("Delete Playlist", systemImage: "trash") }
            } else {
                Button { sharing = true } label: { Label("People…", systemImage: "person.2") }
                Divider()
                Button(role: .destructive) { leaving = true } label: {
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
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.commaSeparatedText, .json], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            let opened = urls.filter { $0.startAccessingSecurityScopedResource() }
            SpotifyImporter.shared.start(urls, into: current.id, library: library)
            opened.forEach { $0.stopAccessingSecurityScopedResource() }
        }
        .alert("Import a YouTube Playlist", isPresented: $askingLink) {
            TextField("music.youtube.com/playlist?list=…", text: $link).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) { link = "" }
            Button("Import") { SpotifyImporter.shared.start(link: link, into: current.id, library: library); link = "" }
        } message: {
            Text("A public or unlisted playlist from YouTube or YouTube Music. Its songs are added to this playlist.")
        }
        .sheet(isPresented: $sharing) { SharePlaylistSheet(playlist: current) }
        .confirmationDialog("Leave “\(current.name)”?", isPresented: $leaving, titleVisibility: .visible) {
            Button("Leave", role: .destructive) { Task { await library.leave(current); dismiss() } }
        } message: {
            Text("It stays on its owner's list. Ask them to share it again to come back.")
        }
        .confirmationDialog("Delete “\(current.name)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await library.deletePlaylist(current); dismiss() } }
        } message: {
            Text("This can't be undone.")
        }
    }
}

/// Who is on a playlist, and (its owner) inviting someone: a username (or a tap on a friend) and what they may do.
/// Sharing again with the same person changes their role; the owner removes people by swiping. Someone it is shared
/// with sees the list only. The sheet stays open after an invite, so the new person shows in the list.
struct SharePlaylistSheet: View {
    let playlist: PlaylistSummary
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @State private var members: [PlaylistMember] = []
    @State private var username = ""
    @State private var role = "viewer"
    @State private var problem: String?
    @State private var working = false
    @State private var copied = false

    private var trimmed: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(members) { member in
                        HStack(spacing: 12) {
                            Avatar(name: member.username, size: 34)
                            Text(member.username)
                            Spacer()
                            Text(member.roleName).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .swipeActions(edge: .trailing) {
                            if playlist.isOwner, member.role != "owner" {
                                Button("Remove", role: .destructive) { remove(member) }
                            }
                        }
                    }
                } header: {
                    Text("People")
                } footer: {
                    if playlist.isOwner { Text("Swipe a person to remove them.") }
                }
                if playlist.isOwner { invite }
                Section {
                    ShareLink(item: PlaylistLink.web(playlist.id)) { Label("Share Link…", systemImage: "square.and.arrow.up") }
                    Button {
                        UIPasteboard.general.string = PlaylistLink.web(playlist.id).absoluteString
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link")
                    }
                } footer: {
                    Text(playlist.isPublic ? "Anyone with an account on this server can open it." : "People it is shared with can open it.")
                }
            }
            .navigationTitle(playlist.isOwner ? "Share “\(playlist.name)”" : "People on “\(playlist.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await loadMembers() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var invite: some View {
        Section {
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(go)
                .onChange(of: username) { problem = nil }
            // friends not on the playlist yet: a tap fills the name
            let suggestions = Social.shared.friends.filter { friend in !members.contains { $0.username == friend.username } }
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { friend in
                            Button { username = friend.username } label: {
                                HStack(spacing: 6) {
                                    Avatar(name: friend.username, size: 22)
                                    Text(friend.username).font(.callout)
                                }
                                .padding(.leading, 5).padding(.trailing, 12).padding(.vertical, 5)
                                .background(.primary.opacity(username == friend.username ? 0.16 : 0.07), in: .capsule)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Picker("They can", selection: $role) {
                Text("View only").tag("viewer")
                Text("Make changes").tag("editor")
            }
            .pickerStyle(.segmented)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle.fill").font(.callout).foregroundStyle(.red)
            }
            Button("Share", action: go).disabled(trimmed.isEmpty || working)
        } header: {
            Text("Add someone")
        }
    }

    private func loadMembers() async {
        if let found = try? await API.members(of: playlist.id) { members = found }
    }

    private func go() {
        guard !trimmed.isEmpty, !working else { return }
        working = true
        Task {
            problem = await library.share(playlist, with: trimmed, role: role)
            working = false
            if problem == nil {
                username = ""
                await loadMembers()
            }
        }
    }

    private func remove(_ member: PlaylistMember) {
        Task {
            do {
                try await API.removeMember(member.userID, from: playlist.id)
                await loadMembers()
            } catch {
                problem = error.localizedDescription
            }
        }
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
