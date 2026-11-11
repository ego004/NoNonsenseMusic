import SwiftUI

/// "Add to Playlist…" (Mac and iPhone), the Spotify way: every playlist you may add to, with a ✓ where it already has the
/// song and a + where it does not. A + adds the song; a ✓ asks what to do (Add Again, which makes a second row, or Remove,
/// which takes out every row of the song). The playlists' rows come from `LibraryStore.loadMembership`: ones you have
/// opened are known at once, the rest load as the sheet opens, and their rows show a spinner until then.
struct AddToPlaylistSheet: View {
    let track: Track
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var asking: PlaylistSummary?
    #if !os(macOS)
    @State private var creating = false
    #endif

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add to Playlist").font(.headline)
                    Text(track.title).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            list
        }
        .frame(width: 380, height: 460)
        #else
        NavigationStack {
            list
                .navigationTitle("Add “\(track.title)”")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .newPlaylistAlert($creating, adding: track)
        }
        .presentationDetents([.medium, .large])
        #endif
    }

    private var list: some View {
        List {
            Section {
                Button {
                    #if os(macOS)
                    dismiss()
                    library.newPlaylistRequest = .init(track: track)
                    #else
                    creating = true
                    #endif
                } label: {
                    Label("New Playlist…", systemImage: "plus")
                }
            }
            Section {
                let editable = library.playlists.filter(\.canEdit)
                if editable.isEmpty {
                    Text("No playlists yet.").foregroundStyle(.secondary)
                }
                ForEach(editable) { playlist in row(playlist) }
            }
        }
        .task { await library.loadMembership() }
        .confirmationDialog(asking.map { "Already in “\($0.name)”" } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                            titleVisibility: .visible, presenting: asking) { playlist in
            Button("Add Again") { Task { await library.add(track, to: playlist, allowDuplicate: true) } }
            Button("Remove from Playlist", role: .destructive) {
                let rows = library.entries(of: track, in: playlist) ?? []
                Task { for row in rows { await library.remove(row, from: playlist.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { playlist in
            Text("“\(track.title)” is in this playlist. A second copy makes it play twice.")
        }
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        let rows = library.entries(of: track, in: playlist)
        return Button {
            if let rows, !rows.isEmpty { asking = playlist } else { Task { await library.add(track, to: playlist) } }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).lineLimit(1)
                    Text(rows.map { $0.isEmpty ? playlist.songsText : "Already added" } ?? playlist.songsText)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if rows == nil {
                    ProgressView().controlSize(.small)
                } else if rows?.isEmpty == true {
                    Image(systemName: "plus.circle").foregroundStyle(.secondary)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(rows == nil)
        .accessibilityLabel(playlist.name)
        .accessibilityValue(rows.map { $0.isEmpty ? "Not added" : "Already added" } ?? "Checking")
    }
}
