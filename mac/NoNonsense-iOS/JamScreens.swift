import SwiftUI
import UIKit

/// The Jam button: opens the jam sheet. Filled while you are in a jam.
struct JamButton: View {
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: JamSession.shared.state != nil ? "person.2.wave.2.fill" : "person.2.wave.2")
        }
        .accessibilityLabel("Jam")
        .accessibilityValue(JamSession.shared.state != nil ? "In a jam" : "Not in a jam")
        .sheet(isPresented: $shown) { JamSheet() }
    }
}

/// A jam: not in one, start one or join with its code; in one, the room.
struct JamSheet: View {
    @Environment(\.dismiss) private var dismiss
    private var jam: JamSession { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if let room = jam.state { JamRoom(room: room) } else { JamStart() }
            }
            .navigationTitle("Jam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // presented from Now Playing, whose white text would otherwise carry in and vanish on the sheet's light background
        .foregroundStyle(Color(.label))     // an explicit colour: .primary would derive from the white
        .presentationDetents([.medium, .large])
    }
}

/// Not in a jam: start one, or join one with its code.
private struct JamStart: View {
    @State private var code = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        List {
            Section {
                Button { go { await JamSession.shared.start(named: nil) } } label: {
                    Text("Start a Jam").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(.white)                  // the sheet's label colour (JamSheet) would otherwise darken it
                .controlSize(.large)
                .disabled(working)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section("Join with a code") {
                HStack {
                    TextField("Code", text: $code)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(join)
                    Button("Join", action: join)
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
                if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            }
        }
        .onChange(of: code) { problem = nil }
    }

    private func join() { go { await JamSession.shared.join(code: code) } }

    private func go(_ action: @escaping () async -> String?) {
        working = true
        Task {
            problem = await action()
            working = false
        }
    }
}

/// In a jam: the code to share, where it plays, the song and its controls, Up Next, the people, and Leave.
private struct JamRoom: View {
    @Environment(LibraryStore.self) private var library
    let room: JamState
    @State private var copied = false
    private var jam: JamSession { .shared }
    private var device: String { UIDevice.current.model }       // "iPhone" or "iPad"
    private var host: String { room.members.first { $0.userID == room.hostID }?.username ?? "Someone" }

    var body: some View {
        List {
            Section {
                // the name on its own line: beside the code it was cut to "iphonetest0324's J…"
                VStack(alignment: .leading, spacing: 8) {
                    Text(room.name ?? "\(host)'s Jam").font(.headline).lineLimit(2)
                    Button {
                        UIPasteboard.general.string = room.code
                        copied = true
                    } label: {
                        Label(room.code.uppercased(), systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(.callout, design: .monospaced).weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Copies the code: others join with it")
                }
                Label(playingOn, systemImage: "hifispeaker.fill").font(.callout).foregroundStyle(.secondary)
                if !jam.isHost, !room.onlyHostPlays {
                    Toggle("Play here", isOn: Binding(get: { jam.playHere }, set: { jam.playHere = $0 }))
                }
                if jam.isHost, room.members.count > 1 {
                    Toggle("Only this \(device) plays", isOn: Binding(get: { room.onlyHostPlays }, set: { jam.setOnlyHostPlays($0) }))
                    Toggle("Only I control playback", isOn: Binding(get: { room.onlyHostControls }, set: { jam.setOnlyHostControls($0) }))
                }
                if !jam.isHost, room.onlyHostControls {
                    Text(JamSession.lockedNotice).font(.callout).foregroundStyle(.secondary)
                }
            }

            Section("Now Playing") { nowPlaying }

            if !room.queue.isEmpty {
                Section("Up Next") {
                    ForEach(room.queue) { entry in
                        Button { jam.jump(to: entry) } label: { entryRow(entry) }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { jam.remove(entry) } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                    .onMove { source, destination in
                        guard let from = source.first else { return }
                        jam.move(room.queue[from], to: destination > from ? destination - 1 : destination)
                    }
                }
            } else if room.current != nil {
                Section { Text("Play any song to add it to the jam.").font(.callout).foregroundStyle(.secondary) }
            }

            Section("People") {
                ForEach(room.members) { member in
                    HStack(spacing: 12) {
                        Avatar(name: member.username, size: 32)
                        Text(member.username)
                        if member.userID == room.hostID { Text("Host").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        if jam.isHost, member.userID != room.hostID {
                            Button(role: .destructive) { Task { await jam.remove(member) } } label: { Label("Remove", systemImage: "person.badge.minus") }
                        }
                    }
                    .contextMenu {
                        if jam.isHost, member.userID != room.hostID {
                            Button("Make \(member.username) the host") { Task { await jam.giveSpeakers(to: member) } }
                        }
                    }
                }
                if jam.isHost { InviteList(room: room) }
            }

            if let problem = jam.problem { Section { Text(problem).font(.callout).foregroundStyle(.red) } }

            Section {
                Button("Leave Jam", role: .destructive) { Task { await jam.leave() } }
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: room.code) { copied = false }
    }

    private var playingOn: String {
        room.onlyHostPlays ? (jam.isHost ? "Playing on this \(device) only" : "Playing on \(host)'s device")
            : jam.isHost || jam.playHere ? "Playing on every device" : "Silent here, playing on the others"
    }

    @ViewBuilder private var nowPlaying: some View {
        if let entry = room.current {
            HStack(spacing: 12) {
                Cover(url: entry.listing.image.flatMap(URL.init(string:)), size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.listing.title).fontWeight(.semibold).lineLimit(1)
                    Text(entry.listing.artists.joined(separator: ", ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                // what this button shows is the room's state, so a phone still loading the room's song cannot pause it for everyone
                Button { jam.setPlaying(!room.isPlaying) } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(room.isPlaying ? "Pause" : "Play")
                Button { jam.skip() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 36, height: 36) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next")
            }
        } else {
            Text("Nothing playing. Play any song to start the jam.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func entryRow(_ entry: JamEntry) -> some View {
        HStack(spacing: 12) {
            Cover(url: entry.listing.image.flatMap(URL.init(string:)), size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.listing.title).lineLimit(1)
                Text(entry.listing.artists.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// The host's invitations: friends not in the room yet. Each invite sends them a notification with the code.
private struct InviteList: View {
    @Environment(LibraryStore.self) private var library
    let room: JamState
    @State private var sent: Set<String> = []

    var body: some View {
        let members = Set(room.members.map(\.username))
        let friends = Social.shared.friends.filter { !members.contains($0.username) }
        Menu {
            if friends.isEmpty { Text("Add friends to invite them") }
            ForEach(friends) { friend in
                Button(sent.contains(friend.username) ? "\(friend.username) (Invited)" : friend.username) {
                    Task {
                        if let problem = await JamSession.shared.invite(friend.username) { library.notify(problem, symbol: "exclamationmark.triangle.fill") }
                        else { sent.insert(friend.username) }
                    }
                }
                .disabled(sent.contains(friend.username))
            }
        } label: {
            Label("Invite a Friend", systemImage: "person.badge.plus")
        }
    }
}
