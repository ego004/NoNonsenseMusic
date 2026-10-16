import SwiftUI

/// Jam in the toolbar, beside the bell (15 Oct, as in the Windows app): the people and the word, in the accent colour
/// with LIVE while you are in a jam. Its popover starts or joins a jam, and in one shows the room: its code, who plays,
/// the song, Up Next and the people.
struct JamButton: View {
    private var jam: JamSession { .shared }
    private var panel: JamPanelState { .shared }

    var body: some View {
        Button { panel.shown.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: jam.inJam ? "person.2.wave.2.fill" : "person.2.wave.2")
                    .contentTransition(.symbolEffect(.replace))
                Text("Jam").selfTestFrame("jam.title")
                if jam.inJam {
                    Text("LIVE")
                        .tracking(0.8)
                        .textStyle(size: 10.5, weight: .heavy)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.tint.opacity(0.2), in: .capsule)
                        #if DEBUG
                        .onAppear { SelfTest.jamLive = true }
                        .onDisappear { SelfTest.jamLive = false }
                        #endif
                }
            }
            .textStyle(size: 14, weight: .semibold)
            .foregroundStyle(jam.inJam ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .help(jam.inJam ? "Jam" : "Start or Join a Jam")
        .accessibilityLabel("Jam")
        .accessibilityValue(jam.inJam ? "Live" : "")                        // LIVE was not said (#32)
        .popover(isPresented: Binding(get: { panel.shown }, set: { panel.shown = $0 }), arrowEdge: .bottom) {
            JamPanel().frame(width: 340)
        }
    }
}

/// Whether the Jam panel is open: the toolbar's Jam opens it, and so does the command bar's "Start or Join a Jam".
@Observable final class JamPanelState {
    static let shared = JamPanelState()
    var shown = false
}

private struct JamPanel: View {
    private var jam: JamSession { .shared }

    var body: some View {
        if let room = jam.state { RoomView(room: room) } else { StartView() }
    }
}

/// Not in a jam: start one, or join one with its code.
private struct StartView: View {
    @Environment(\.textScale) private var textScale
    @State private var code = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Jam", systemImage: "person.2.wave.2").textStyle(.headline)
            Button { go { await JamSession.shared.start(named: nil) } } label: {
                Text("Start a Jam").frame(maxWidth: .infinity)
            }
            .compatGlassButton(prominent: true)
            .controlSize(.large)
            .disabled(working)
            HStack(spacing: 8) {
                TextField("Code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: Font.TextStyle.body.macPointSize * textScale, design: .monospaced))   // the text size (#32)
                    .autocorrectionDisabled()
                    .onSubmit { join() }
                Button("Join", action: join)
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if let problem {
                Text(problem).textStyle(.callout).foregroundStyle(.red)
            }
        }
        .padding(18)
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
private struct RoomView: View {
    let room: JamState
    @Environment(\.textScale) private var textScale
    @State private var copied = false
    private var jam: JamSession { .shared }

    private var host: String { room.members.first { $0.userID == room.hostID }?.username ?? "Someone" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(room.name ?? "\(host)'s Jam").textStyle(.headline).lineLimit(1)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(room.code, forType: .string)
                    copied = true
                } label: {
                    Label(room.code.uppercased(), systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: Font.TextStyle.callout.macPointSize * textScale, weight: .semibold, design: .monospaced))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.quiet)
                .help("Copy the code: others join with it")
                .accessibilityLabel("Copy the Code, \(room.code.lowercased().map(String.init).joined(separator: " "))")   // said letter by letter
                .selfTestFrame("jam.code")
            }

            HStack(spacing: 6) {
                Image(systemName: "hifispeaker.fill").foregroundStyle(.secondary)
                Text(room.onlyHostPlays ? (jam.isHost ? "Playing on this Mac only" : "Playing on \(host)'s device")
                     : jam.isHost || jam.playHere ? "Playing on every device" : "Silent here, playing on the others")
                    .textStyle(.callout).foregroundStyle(.secondary)
                Spacer()
                if !jam.isHost, !room.onlyHostPlays {
                    Toggle("Play here", isOn: Binding(get: { jam.playHere }, set: { jam.playHere = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).textStyle(.callout)
                        .help("Off: this Mac follows the jam without sound, for friends in the same room")
                }
                // where the jam plays: every device (the default) or this Mac only, and who hosts. Only with someone
                // else in the room, the only time it means anything
                if jam.isHost, room.members.count > 1 {
                    Menu("Speakers") {
                        Toggle("Only this Mac plays", isOn: Binding(get: { room.onlyHostPlays }, set: { jam.setOnlyHostPlays($0) }))
                        Toggle("Only I control playback", isOn: Binding(get: { room.onlyHostControls }, set: { jam.setOnlyHostControls($0) }))
                        Divider()
                        ForEach(room.members.filter { $0.userID != room.hostID }) { member in
                            Button("Make \(member.username) the host") { Task { await jam.giveSpeakers(to: member) } }
                        }
                    }
                    .controlSize(.small)
                    .help("Choose where the jam plays")
                }
            }
            // a member while the host controls the room: their play, skip and seek would be refused, so they are told why
            if !jam.isHost, room.onlyHostControls {
                Text(JamSession.lockedNotice).textStyle(.callout).foregroundStyle(.secondary)
            }

            nowPlaying

            if !room.queue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Up Next").textStyle(.subheadline, weight: .semibold).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(room.queue) { entry in EntryRow(entry: entry) }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            } else if room.current != nil {
                Text("Play any song to add it to the jam.").textStyle(.caption).foregroundStyle(.secondary)
            }

            HStack {
                HStack(spacing: -6) {
                    ForEach(room.members) { member in
                        Avatar(name: member.username, size: 26)
                            .help(member.username)
                            // the avatar is hidden from VoiceOver (a picture of a letter): who is in the room was not said (#32)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(member.userID == room.hostID ? "\(member.username), host" : member.username)
                            .accessibilityActions {
                                if jam.isHost, member.userID != room.hostID {
                                    Button("Remove \(member.username) from the Jam") { Task { await jam.remove(member) } }
                                }
                            }
                            .contextMenu {
                                if jam.isHost, member.userID != room.hostID {
                                    Button("Remove \(member.username) from the Jam", role: .destructive) {
                                        Task { await jam.remove(member) }
                                    }
                                }
                            }
                    }
                }
                .padding(.leading, 6)
                Spacer()
                if jam.isHost { InviteMenu(room: room) }
            }

            if let problem = jam.problem {
                Text(problem).textStyle(.callout).foregroundStyle(.red)
            }

            Button("Leave Jam", role: .destructive) { Task { await jam.leave() } }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(18)
        .selfTestFrame("jam.room")
    }

    @ViewBuilder private var nowPlaying: some View {
        if let entry = room.current {
            HStack(spacing: 10) {
                ArtworkView(url: entry.listing.image.flatMap(URL.init(string:)), size: 44, radius: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.listing.title).textStyle(.callout, weight: .semibold).lineLimit(1)
                    Text(entry.listing.artists.joined(separator: ", ")).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button { jam.togglePlay() } label: {
                    Image(systemName: room.isPlaying ? "pause.fill" : "play.fill").font(.title3).frame(width: 28, height: 28)
                }
                .buttonStyle(.quiet)
                .help(room.isPlaying ? "Pause" : "Play")
                .accessibilityLabel(room.isPlaying ? "Pause" : "Play")                  // they had no names (#32)
                Button { jam.skip() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 28, height: 28)
                }
                .buttonStyle(.quiet)
                .help("Next")
                .accessibilityLabel("Next")
            }
            .padding(8)
            .background(.primary.opacity(0.05), in: .rect(cornerRadius: 10, style: .continuous))
        } else {
            Text("Nothing playing. Play any song to start the jam.")
                .textStyle(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// The host's Invite menu: friends not in the room yet. Each invite sends them a notification with the code.
private struct InviteMenu: View {
    let room: JamState
    @State private var sent: Set<String> = []

    var body: some View {
        let members = Set(room.members.map(\.username))
        let friends = Social.shared.friends.filter { !members.contains($0.username) }
        Menu {
            if friends.isEmpty {
                Text("Add friends to invite them")
            }
            ForEach(friends) { friend in
                Button(sent.contains(friend.username) ? "\(friend.username) (Invited)" : friend.username) {
                    Task { if await JamSession.shared.invite(friend.username) == nil { sent.insert(friend.username) } }
                }
                .disabled(sent.contains(friend.username))
            }
        } label: {
            Label("Invite", systemImage: "person.badge.plus")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .help("Invite a friend to this jam")
    }
}

/// A song in the jam's Up Next: click to play it now, × to remove it.
private struct EntryRow: View {
    let entry: JamEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ArtworkView(url: entry.listing.image.flatMap(URL.init(string:)), size: 30, radius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.listing.title).textStyle(.callout).lineLimit(1)
                Text(entry.listing.artists.joined(separator: ", ")).textStyle(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { JamSession.shared.remove(entry) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.quiet)
                .opacity(hovering ? 1 : 0)
                .help("Remove from the jam")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 7, style: .continuous))
        .contentShape(.rect)
        .onTapGesture(count: 2) { JamSession.shared.jump(to: entry) }
        .onHover { hovering = $0 }
        .help("Double-click to play now")
        // one element: the song, Play Now as its press, Remove as an action (the ✕ shows only under the pointer; #32)
        .accessibleTile("\(entry.listing.title), \(entry.listing.artists.joined(separator: ", "))") { JamSession.shared.jump(to: entry) }
        .accessibilityAction(named: "Remove from the Jam") { JamSession.shared.remove(entry) }
    }
}
