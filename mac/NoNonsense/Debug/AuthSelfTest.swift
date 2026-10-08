#if DEBUG
import AppKit

/// Accounts in self-tests (AUTH-1, 8 Oct): every route needs a signed-in account, so every self-test signs one up.
extension SelfTest {
    static let testPassword = "a test password"
    private static var startedAuth = false

    /// A fresh `test-<random>` account, signed up at launch (AccountGate), its token in memory only
    /// (`Account(keychain: false)`): your Keychain token is never read or replaced. Only on the test server this app
    /// started itself: never on yours. The backend's test run deletes `test-` accounts.
    static func signUpTestAccount(_ account: Account) async {
        guard await onOwnTestServer() else { report("no test account: this app did not start this server (never yours)"); return }
        let name = "test-" + String(UInt32.random(in: 0 ... .max), radix: 16)
        if let problem = await account.signIn(name, testPassword, create: true) { report("could not sign up \(name): \(problem)") }
        else { report("signed up \(name)") }
    }

    /// With `NN_SELFTEST_AUTH=1` (own test server): accounts and sharing through the app's own Account, LibraryStore
    /// and Player, as the window uses them. No search: the songs are made up (a JioSaavn id nobody has; the server
    /// keeps a song from its details alone), so it runs where the music sources cannot be reached. Pictures of the
    /// screens with NN_SELFTEST_SNAP. Reports PASS or FAIL per rule, then quits.
    static func runAuthCheckIfAsked(account: Account, library: LibraryStore, player: Player) {
        guard ProcessInfo.processInfo.environment["NN_SELFTEST_AUTH"] != nil, !startedAuth else { return }
        startedAuth = true
        Task {
            var failures = 0
            @MainActor func check(_ rule: String, _ ok: Bool, _ got: String = "") {
                if !ok { failures += 1 }
                report("auth \(ok ? "PASS" : "FAIL") \(rule)\(ok || got.isEmpty ? "" : " (got \(got))")")
            }
            @MainActor func done() {
                report("auth: \(failures == 0 ? "all checks pass" : "\(failures) FAILED")")
                NSApp.terminate(nil)
            }
            guard await onOwnTestServer(), account.state == .signedIn, let owner = account.user, let ownerToken = API.token else {
                report("auth: this app's own test server and a signed-up test account needed"); NSApp.terminate(nil); return
            }
            if !player.isMuted { player.toggleMute() }                                  // tests stay silent

            // signed in
            check("GET /auth/me knows the account", (try? await API.me())?.username == owner.username)
            check("the device name starts as this Mac's name, 1 to 64 characters", (1...64).contains(Account.computerName.count))
            // renaming this device; your own saved name is put back after (the test app shares your preferences)
            let savedName = UserDefaults.standard.string(forKey: "deviceName")
            check("rename this device", await account.renameDevice("Self-test Mac") == nil && Account.deviceName == "Self-test Mac")
            check("…an empty name is refused here, before the server", await account.renameDevice("  ") != nil)
            UserDefaults.standard.set(savedName, forKey: "deviceName")
            await library.refresh()
            check("a new account starts with an empty library", library.liked.isEmpty && library.recent.isEmpty && library.playlists.isEmpty)
            try? await Task.sleep(for: .seconds(1))
            check("signed in, the window shows the library", frames["sidebar.title:Home"] != nil && !signInShowing())
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let frame = window.contentView?.superview {
                let blurs = descendants(of: frame).compactMap { $0 as? NSVisualEffectView }
                report("after sign-in: behind-window blurs \(blurs.filter { $0.blendingMode == .behindWindow }.count), within-window \(blurs.filter { $0.blendingMode == .withinWindow }.count), text fields \(descendants(of: frame).filter { $0 is NSTextField && ($0 as! NSTextField).isEditable }.count), window opaque \(window.isOpaque)")
            }
            snap("auth-signed-in")

            // the toolbar's small title shows only once the big one has scrolled under it (8 Oct: they overlapped)
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
               let scroll = descendants(of: window.contentView!).compactMap({ $0 as? NSScrollView })
                   .max(by: { $0.frame.height < $1.frame.height }) {
                check("at the top of Home, no small title in the toolbar", window.title.isEmpty, "title “\(window.title)”")
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
                scroll.reflectScrolledClipView(scroll.contentView)
                try? await Task.sleep(for: .milliseconds(400))
                check("scrolled down, the small title appears", window.title == "Home", "title “\(window.title)”")
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }

            // the player's address: /play is asked with the token, and its redirect is not followed (handoff 3.2)
            let song = madeUp("Auth test song")
            let bare = (try? await URLSession.shared.data(from: API.playURL(song.best)))?.1 as? HTTPURLResponse
            check("without the token /play answers 401", bare?.statusCode == 401, "\(bare?.statusCode ?? 0)")
            var answer = 0
            do { _ = try await API.audioURL(song.best); answer = 307 } catch API.Failure.http(let code, _) { answer = code } catch {}
            check("with it /play answers (a made-up song has no audio: 404 or 502, never 401)", answer != 401 && answer != 0, "\(answer)")
            check("…and you are still signed in", account.state == .signedIn)

            // your playlist, shared
            check("create a playlist", await library.createPlaylist(named: "Auth test") == nil)
            guard let mine = library.ownPlaylists.first(where: { $0.name == "Auth test" }) else { done(); return }
            await library.add(song, to: mine)
            check("…yours and private", mine.isOwner && !mine.isPublic)
            let id = mine.id.uuidString.lowercased()
            // a second account, signed up beside the app (its own token; the app stays signed in as the owner)
            let friendName = "test-" + String(UInt32.random(in: 0 ... .max), radix: 16)
            guard let friend = try? await API.signUp(friendName, testPassword, device: "self-test") else {
                check("sign up a second account", false); done(); return
            }
            check("sharing with nobody says so", await library.share(mine, with: "test-nobody-has-this-name", role: "viewer") == "No account with that username")
            check("share as a viewer", await library.share(mine, with: friendName, role: "viewer") == nil)
            let viewerAdd = await raw("POST", "playlists/\(id)/items", token: friend.token, body: listings(madeUp("Viewer's song")))
            check("a viewer cannot add: 403 and the server's reason",
                  viewerAdd.status == 403 && API.detail(viewerAdd.body) == "Your role on this playlist does not allow that",
                  "\(viewerAdd.status) \(API.detail(viewerAdd.body) ?? "")")
            check("share again as an editor", await library.share(mine, with: friendName, role: "editor") == nil)
            // its link: the web address to share, and the app's own; both name this playlist
            let web = PlaylistLink.web(mine.id)
            check("the shared link is the server's /p/<id> page", web.absoluteString == API.baseURL.absoluteString + "/p/" + mine.id.uuidString.lowercased(), web.absoluteString)
            check("…and both kinds of link read back to the playlist",
                  PlaylistLink.playlistID(in: web) == mine.id
                  && PlaylistLink.playlistID(in: URL(string: "nononsense://playlist/\(mine.id.uuidString.lowercased())")!) == mine.id
                  && PlaylistLink.playlistID(in: URL(string: "nononsense://playlist/not-an-id")!) == nil)
            let people = (try? await API.members(of: mine.id)) ?? []
            check("the members list: the owner, then the editor", people.map(\.role) == ["owner", "editor"] && people.last?.username == friendName,
                  people.map { "\($0.username) \($0.role)" }.joined(separator: ", "))
            await library.setPublic(mine, true)
            check("make it public", library.ownPlaylists.first { $0.id == mine.id }?.isPublic == true)
            var code = await raw("POST", "playlists/\(id)/items", token: friend.token, body: listings(madeUp("Editor's song"))).status
            check("an editor can add", code == 201, "\(code)")

            // Sign Out, with a song loading: the sign-in screen, nothing playing, nothing of the account left
            player.play([song])
            await account.signOut()
            check("Sign Out: the sign-in screen, with no notice (you chose it)", account.state == .signedOut && account.notice == nil && API.token == nil)
            check("…the player stopped and emptied", player.current == nil && !player.isPlaying && player.queue.isEmpty)
            check("…the library emptied", library.playlists.isEmpty && library.liked.isEmpty && library.recent.isEmpty)
            code = await raw("GET", "auth/me", token: ownerToken).status
            check("…and the session ended on the server, not only here", code == 401, "\(code)")
            try? await Task.sleep(for: .seconds(1))
            check("the window shows the sign-in screen", signInShowing())
            snap("auth-signed-out")

            // the second account in the app: the playlist under Shared with You, as an editor
            check("a wrong password says so", await account.signIn(friendName, "wrong password", create: false) == "Wrong username or password")
            check("…and signs nobody in", account.state == .signedOut)
            frames["sidebar.title:Auth test"] = nil
            check("sign in as the second account", await account.signIn(friendName, testPassword, create: false) == nil && account.state == .signedIn)
            await library.refresh()
            let shared = library.sharedPlaylists.first { $0.id == mine.id }
            check("their own list is empty; the playlist is shared with them", library.ownPlaylists.isEmpty && shared != nil)
            check("…as an editor, public, with both songs", shared?.role == "editor" && shared?.isPublic == true && shared?.songCount == 2,
                  "\(shared?.role ?? "-") \(shared?.isPublic ?? false) \(shared?.songCount ?? 0)")
            try? await Task.sleep(for: .seconds(1))
            check("…and in the sidebar", frames["sidebar.title:Auth test"] != nil)
            NotificationCenter.default.post(name: .selfTestOpen, object: mine.id)
            try? await Task.sleep(for: .seconds(1.5))
            snap("auth-shared-playlist")
            if let shared { await library.leave(shared) }
            check("Leave: gone from their list", !library.playlists.contains { $0.id == mine.id })

            // the session signed out on another device: the next request brings the sign-in screen back, saying why
            code = await raw("POST", "auth/signout", token: API.token ?? "").status
            check("(the session ends elsewhere)", code == 204, "\(code)")
            await library.refresh()
            check("a session ended elsewhere: the sign-in screen, saying why", account.state == .signedOut && (account.notice ?? "").contains("signed out"),
                  account.notice ?? "no notice")
            check("…not \"Server not connected\"", Connectivity.shared.serverAnswers)
            try? await Task.sleep(for: .seconds(1))
            check("…on screen", signInShowing())
            snap("auth-session-ended")

            // the owner keeps the playlist; then everything this test made is removed
            check("sign in again as the owner", await account.signIn(owner.username, testPassword, create: false) == nil)
            await library.refresh()
            check("the owner's playlist stayed", library.ownPlaylists.contains { $0.id == mine.id })
            if let p = library.ownPlaylists.first(where: { $0.id == mine.id }) { await library.deletePlaylist(p) }
            await account.signOut()
            _ = await raw("POST", "auth/signout", token: friend.token)
            done()
        }
    }

    /// A song nobody has: a made-up JioSaavn id. The server stores it from these details alone; it has no audio.
    private static func madeUp(_ title: String) -> Track {
        let listing = Listing(source: "jiosaavn", id: "selftest-\(UInt32.random(in: 0 ... .max))", title: title, artists: ["Self-test"],
                              album: nil, duration: 200, popularity: nil, image: nil)
        return Track(best: listing, listings: [listing])
    }

    private static func listings(_ track: Track) -> Data {
        struct Body: Encodable { let listings: [Listing] }
        return (try? JSONEncoder().encode(Body(listings: track.listings))) ?? Data()
    }

    /// A request with a token that is not the app's: a second account, or a session the app no longer holds.
    private static func raw(_ method: String, _ path: String, token: String, body: Data? = nil) async -> (status: Int, body: Data) {
        var request = URLRequest(url: API.baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (0, Data()) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// The sign-in screen is the one with a password field.
    private static func signInShowing() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let frame = window.contentView?.superview else { return false }
        return descendants(of: frame).contains { $0 is NSSecureTextField }
    }
}
#endif
