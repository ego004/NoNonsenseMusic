import SwiftUI

/// The Friends screen: requests waiting on you (Accept, Decline), the ones you sent, then your friends. Add Friend
/// sends a request by username. Kept up to date by Social's socket, so it needs no refresh button.
struct FriendsView: View {
    @State private var adding = false
    @State private var removing: Friend?
    private var social: Social { .shared }

    var body: some View {
        List {
            HStack(alignment: .bottom) {
                Text("Friends").textStyle(.largeTitle, weight: .bold).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { adding = true } label: { Label("Add Friend", systemImage: "person.badge.plus") }
                    .compatGlassButton(prominent: true)
                    .controlSize(.large)
            }
            .browseRow(top: 20, bottom: 12)

            if !social.incoming.isEmpty {
                sectionTitle("Requests")
                ForEach(social.incoming) { person in
                    PersonRow(name: person.username, detail: "Wants to be friends") {
                        Button("Decline") { Task { await social.respond(to: person.username, accept: false) } }
                            .compatGlassButton()
                        Button("Accept") { Task { await social.respond(to: person.username, accept: true) } }
                            .compatGlassButton(prominent: true)
                    }
                    .browseRow(top: 2, bottom: 2, inset: 16)
                }
            }
            if !social.outgoing.isEmpty {
                sectionTitle("Sent")
                ForEach(social.outgoing) { person in
                    PersonRow(name: person.username, detail: "Request sent \(Self.day(person.since))") { EmptyView() }
                        .browseRow(top: 2, bottom: 2, inset: 16)
                }
            }
            if !social.friends.isEmpty {
                sectionTitle("Your Friends")
                ForEach(social.friends) { friend in
                    PersonRow(name: friend.username, detail: "Friends since \(Self.day(friend.since))") { EmptyView() }
                        .contextMenu { Button("Remove Friend…", role: .destructive) { removing = friend } }
                        .browseRow(top: 2, bottom: 2, inset: 16)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
        .scrollTitle("Friends")
        .sheet(isPresented: $adding) { AddFriendSheet { adding = false } }
        .confirmationDialog("Remove \(removing?.username ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { friend in
            Button("Remove Friend", role: .destructive) { Task { await social.remove(friend) } }
        }
        .task { await social.refresh() }
        .selfTestFrame("friends.page")
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).textStyle(.title3, weight: .bold).accessibilityAddTraits(.isHeader).browseRow(top: 14, bottom: 4)
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
            Avatar(name: name, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).textStyle(.body, weight: .medium).lineLimit(1)
                Text(detail).textStyle(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { actions() }.controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
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

/// Add Friend: a username, then Send Request. The server's reason shows under the field when it refuses.
private struct AddFriendSheet: View {
    let close: () -> Void
    @State private var username = ""
    @State private var problem: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Friend").textStyle(.headline)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
                .onChange(of: username) { problem = nil }
            if let problem {
                Text(problem).textStyle(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button(working ? "Sending…" : "Send Request", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func send() {
        guard !working else { return }
        working = true
        Task {
            problem = await Social.shared.addFriend(username)
            working = false
            if problem == nil { close() }
        }
    }
}

/// The bell in the toolbar, with the unread count. Its popover lists notifications; opening it marks them read.
struct NotificationsButton: View {
    @State private var open = false
    private var social: Social { .shared }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: social.unread > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(social.unread > 0 ? .palette : .monochrome)
                .foregroundStyle(social.unread > 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary), AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
        }
        .help(social.unread > 0 ? "\(social.unread) new" : "Notifications")
        .accessibilityLabel("Notifications")
        .accessibilityValue(social.unread > 0 ? "\(social.unread) new" : "None new")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            NotificationsList { open = false }
        }
    }
}

/// The notifications, newest first: a friend request (Accept and Decline while it waits), an accepted request, a
/// playlist shared with you (Open).
private struct NotificationsList: View {
    let close: () -> Void
    @Environment(\.textScale) private var textScale
    private var social: Social { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Notifications").textStyle(.headline).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            if social.notifications.isEmpty {
                Text("Nothing yet").textStyle(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(social.notifications) { row($0) }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 340)
        .task {
            try? await Task.sleep(for: .seconds(1.5))                 // the new ones stay marked for a moment
            await social.markAllRead()
        }
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: n.from, size: 30)
            VStack(alignment: .leading, spacing: 6) {
                Text(text(n)).textStyle(.callout).fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue(n.read ? "" : "New")             // the dot alone said so (#32)
                Text(FriendsView.day(n.createdAt)).textStyle(.caption).foregroundStyle(.secondary)
                actions(n)
            }
            Spacer(minLength: 0)
            if !n.read { Circle().fill(.tint).frame(width: 7, height: 7).padding(.top, 5) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func text(_ n: AppNotification) -> AttributedString {
        var name = AttributedString(n.from)
        // at the text size around it (Settings › Appearance › Sizes): .callout stayed at the Mac's (#32)
        name.font = .system(size: Font.TextStyle.callout.macPointSize * textScale, weight: .semibold)
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
                Button("Decline") { Task { await social.respond(to: n.from, accept: false) } }
                Button("Accept") { Task { await social.respond(to: n.from, accept: true) } }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        } else if n.type == "jam_invite", let code = n.payload["code"] {
            if JamSession.shared.state?.code == code {
                Text("You're in this jam").textStyle(.caption).foregroundStyle(.secondary)
            } else {
                Button("Join Jam") { Task { _ = await JamSession.shared.join(code: code); close() } }
                    .controlSize(.small)
            }
        } else if n.type == "playlist_invite", let id = n.payload["playlist_id"].flatMap(UUID.init(uuidString:)) {
            Button("Open Playlist") {
                close()
                Navigator.shared.playlistRequest = id
            }
            .controlSize(.small)
        }
    }
}
