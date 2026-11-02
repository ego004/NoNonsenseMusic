import SwiftUI

/// Friends: who you are friends with, requests waiting for you or sent, and Add Friend by username. The same lists and
/// words as the Mac's Friends page.
struct FriendsScreen: View {
    @Environment(LibraryStore.self) private var library
    @State private var adding = false
    @State private var username = ""
    @State private var removing: Friend?
    private var social: Social { .shared }

    var body: some View {
        List {
            if !social.incoming.isEmpty {
                Section("Requests") {
                    ForEach(social.incoming) { person in
                        PersonRow(name: person.username, detail: "Wants to be friends") {
                            Button("Decline") { Task { await social.respond(to: person.username, accept: false) } }
                                .buttonStyle(.bordered)
                            Button("Accept") { Task { await social.respond(to: person.username, accept: true) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            if !social.outgoing.isEmpty {
                Section("Sent") {
                    ForEach(social.outgoing) { person in
                        PersonRow(name: person.username, detail: "Request sent \(Self.day(person.since))") { EmptyView() }
                    }
                }
            }
            if !social.friends.isEmpty {
                Section("Your Friends") {
                    ForEach(social.friends) { friend in
                        PersonRow(name: friend.username, detail: "Friends since \(Self.day(friend.since))") { EmptyView() }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { removing = friend } label: { Label("Remove", systemImage: "person.badge.minus") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Friends")
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .overlay {
            if social.friends.isEmpty && social.incoming.isEmpty && social.outgoing.isEmpty {
                ContentUnavailableView {
                    Label("No Friends Yet", systemImage: "person.2")
                } description: {
                    Text("Add a friend by their username.")
                } actions: {
                    Button("Add Friend…") { adding = true }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink { NotificationsScreen() } label: {
                    Image(systemName: social.unread > 0 ? "bell.badge" : "bell")
                }
                .accessibilityLabel("Notifications")
                .accessibilityValue(social.unread > 0 ? "\(social.unread) new" : "None new")
                Button { username = ""; adding = true } label: { Image(systemName: "person.badge.plus") }
                    .accessibilityLabel("Add Friend")
            }
        }
        .alert("Add Friend", isPresented: $adding) {
            TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Send Request") {
                Task {
                    if let problem = await social.addFriend(username) { library.notify(problem, symbol: "exclamationmark.triangle.fill") }
                    else { library.notify("Request sent to \(username.trimmingCharacters(in: .whitespaces))", symbol: "person.badge.plus") }
                }
            }
        }
        .confirmationDialog("Remove \(removing?.username ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { friend in
            Button("Remove Friend", role: .destructive) { Task { await social.remove(friend) } }
        }
        .refreshable { await social.refresh() }
        .task { await social.refresh() }
    }

    /// "12 Oct 2026" from the server's ISO 8601 time.
    static func day(_ iso: String) -> String {
        let parsed = (try? Date(iso, strategy: .iso8601)) ?? (try? Date(String(iso.prefix(19)) + "Z", strategy: .iso8601))
        return parsed?.formatted(date: .abbreviated, time: .omitted) ?? ""
    }
}

/// A person: a round initial in a colour of their own, the name, a detail line, and actions on the right.
struct PersonRow<Actions: View>: View {
    let name: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium).lineLimit(1)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                // buttons on their own line: beside the text they were squeezed until "Decline" broke across two
                if Actions.self != EmptyView.self {
                    HStack(spacing: 8) { actions() }.controlSize(.small).padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

/// The first letter of a name in a circle; the colour comes from the name, so a person keeps theirs.
struct Avatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let hue = Double(name.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 } % 360) / 360
        Circle()
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.45, brightness: 0.9),
                                          Color(hue: hue, saturation: 0.6, brightness: 0.72)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Text(name.prefix(1).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The notifications, newest first: a friend request (Accept and Decline while it waits), an accepted request, a playlist
/// shared with you (Open), a jam you are invited to (Join). Opening the list marks them read.
struct NotificationsScreen: View {
    @Environment(LibraryStore.self) private var library
    private var social: Social { .shared }

    var body: some View {
        List {
            ForEach(social.notifications) { row($0) }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PlaylistSummary.self) { PlaylistScreen(playlist: $0) }
        .overlay {
            if social.notifications.isEmpty { ContentUnavailableView("Nothing yet", systemImage: "bell") }
        }
        .task {
            try? await Task.sleep(for: .seconds(1.5))                 // the new ones stay marked for a moment
            await social.markAllRead()
        }
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar(name: n.from, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                Text(text(n)).fixedSize(horizontal: false, vertical: true)
                Text(FriendsScreen.day(n.createdAt)).font(.caption).foregroundStyle(.secondary)
                actions(n)
            }
            Spacer(minLength: 0)
            if !n.read { Circle().fill(.tint).frame(width: 8, height: 8).padding(.top, 6) }
        }
        .padding(.vertical, 2)
    }

    private func text(_ n: AppNotification) -> AttributedString {
        var name = AttributedString(n.from)
        name.font = .body.weight(.semibold)
        switch n.type {
        case "friend_request": return name + AttributedString(" wants to be friends.")
        case "friend_accepted": return name + AttributedString(" accepted your friend request.")
        case "playlist_invite": return name + AttributedString(" shared “\(n.payload["playlist_name"] ?? "a playlist")” with you.")
        case "jam_invite": return name + AttributedString(" invited you to \(n.payload["room_name"].map { "“\($0)”" } ?? "a jam").")
        default: return name
        }
    }

    @ViewBuilder private func actions(_ n: AppNotification) -> some View {
        if n.type == "friend_request", social.incoming.contains(where: { $0.username == n.from }) {
            HStack(spacing: 8) {
                Button("Decline") { Task { await social.respond(to: n.from, accept: false) } }.buttonStyle(.bordered)
                Button("Accept") { Task { await social.respond(to: n.from, accept: true) } }.buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        } else if n.type == "jam_invite", let code = n.payload["code"] {
            if JamSession.shared.state?.code == code {
                Text("You're in this jam").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Join Jam") { Task { _ = await JamSession.shared.join(code: code) } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } else if n.type == "playlist_invite", let id = n.payload["playlist_id"].flatMap(UUID.init(uuidString:)),
                  let playlist = library.playlists.first(where: { $0.id == id }) {
            NavigationLink("Open Playlist", value: playlist).buttonStyle(.bordered).controlSize(.small)
        }
    }
}
