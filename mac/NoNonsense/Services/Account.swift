import Foundation
import Observation
import Security
import SystemConfiguration

/// Who is signed in (AUTH-1), and the token every request carries (`API.token`). The window shows the sign-in screen
/// until this says signedIn; a 401 to the token in use (it expired, or was signed out on another device) brings it
/// back, saying so. Not "Server not connected": the server answered.
@Observable
final class Account {
    enum State { case checking, signedOut, signedIn }

    private(set) var state = State.checking
    private(set) var user: AccountUser?
    /// Why the sign-in screen shows when you did not choose it ("You were signed out…"), or nil.
    private(set) var notice: String?
    /// The session ended (you signed out, or the server said so): the player stops and the library empties, so
    /// nothing of this account stays on screen or keeps playing for the next one.
    @ObservationIgnored var onEnded: (() -> Void)?

    @ObservationIgnored private let store: TokenStore
    @ObservationIgnored private var keychainTurn: Task<Void, Never>?

    /// keychain false: self-tests, which sign up a fresh test account each run and never read or replace yours.
    init(keychain: Bool = true) {
        store = TokenStore(keychain: keychain)
    }

    /// At launch, once the server is up: a stored token is checked with it (`GET /auth/me`). 200: in. 401: the
    /// sign-in screen. No answer (the server stopped): in, as the last known user; the first answer decides.
    func start() async {
        // here, not in init: SwiftUI may build an App's @State starting values more than once, and a discarded
        // Account would have taken the callback with it (see ServerLauncher.shared)
        API.onSignedOut = { [weak self] in self?.ended() }
        guard state == .checking else { return }
        guard let token = await keychain({ $0.read() }) else { state = .signedOut; return }
        API.token = token
        user = savedUser
        do {
            let me = try await API.me()
            user = me
            savedUser = me
            state = .signedIn
        } catch API.Failure.http(401, _) {
            // ended() has run (through API.onSignedOut): the sign-in screen, saying why
        } catch {
            state = .signedIn
        }
    }

    /// Signs in, or makes the account and signs in (`create`). nil when it worked; else the server's reason, shown as
    /// it is ("Wrong username or password", "That username is taken", "Password should have at least 8 characters").
    func signIn(_ username: String, _ password: String, create: Bool) async -> String? {
        do {
            let reply = try await create ? API.signUp(username, password, device: Self.deviceName)
                                         : API.signIn(username, password, device: Self.deviceName)
            API.token = reply.token
            user = reply.user
            savedUser = reply.user
            notice = nil
            state = .signedIn
            await keychain { $0.write(reply.token) }
            return nil
        } catch let failure as API.Failure {
            return failure.localizedDescription
        } catch {
            return "Couldn't reach the server. Check its address in Settings › Server."
        }
    }

    /// Settings › Sign Out: this Mac's session ends on the server and the token is deleted here. If the server cannot
    /// be reached you are signed out here anyway (the session then ends on its own after 30 days unused).
    func signOut() async {
        try? await API.signOut()
        if state != .signedOut { forget() }          // a 401 to the sign-out itself has already done it
        notice = nil                                  // you chose it: nothing to explain
        await keychainTurn?.value
    }

    /// The server answered 401 to the token in use.
    private func ended() {
        guard state != .signedOut else { return }
        forget()
        notice = "You were signed out. Sign in again."
    }

    private func forget() {
        API.token = nil                               // no request carries it from here on
        user = nil
        savedUser = nil
        state = .signedOut
        onEnded?()
        Task { await keychain { $0.delete() } }
    }

    /// Keychain work off the main thread, one at a time and in order. Off: after a rebuild macOS may ask whether this
    /// build may read the token, and that question blocks the thread that asked. In order: a delete finishing after a
    /// quick sign-in would remove the new token.
    private func keychain<T: Sendable>(_ work: @escaping @Sendable (TokenStore) -> T) async -> T {
        let previous = keychainTurn, store = store
        let task = Task.detached { () -> T in
            await previous?.value
            return work(store)
        }
        keychainTurn = Task { _ = await task.value }
        return await task.value
    }

    /// The last signed-in user, for Settings while the server cannot be asked. Not secret: the token is in the Keychain.
    /// Not kept for self-tests: they share your app's settings, and their accounts are not yours.
    private var savedUser: AccountUser? {
        get {
            guard store.keychain else { return nil }
            return UserDefaults.standard.data(forKey: "account.user").flatMap { try? JSONDecoder().decode(AccountUser.self, from: $0) }
        }
        set {
            guard store.keychain else { return }
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "account.user")
        }
    }

    /// This Mac's name as Settings › General › About shows it ("Kai's MacBook Air"), for your list of signed-in
    /// devices (AUTH-4). At most 64 characters, the server's limit. Not Host.current(): it can wait on DNS lookups.
    static var deviceName: String {
        let name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        return String((name.isEmpty ? "Mac" : name).prefix(64))
    }
}

/// The token in the Keychain (a generic password), never in preferences: a plist anyone with the disk can read.
/// The login keychain: the data-protection one needs a signed entitlement, and the app is signed ad hoc (8 Oct).
nonisolated struct TokenStore: Sendable {
    let keychain: Bool

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.nononsense.music.session",
         kSecAttrAccount as String: "token"]
    }

    func read() -> String? {
        guard keychain else { return nil }
        var ask = query
        ask[kSecReturnData as String] = true
        ask[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(ask as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String) {
        guard keychain else { return }
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrLabel as String] = "NoNonsense session"
        SecItemAdd(item as CFDictionary, nil)
    }

    func delete() {
        guard keychain else { return }
        SecItemDelete(query as CFDictionary)
    }
}
