import SwiftUI

/// The sign-in screen until a session exists, then the window as before (AUTH-1). Signing out, or a session that ends
/// (it expired, or was signed out on another device), brings the screen back, saying why.
struct AccountGate<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(Account.self) private var account
    @Environment(ServerLauncher.self) private var server

    var body: some View {
        Group {
            switch account.state {
            case .checking:
                // a moment at launch, longer while the app starts your server
                Text(server.state == .starting ? "Starting Server…" : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { WindowSurface() }
            case .signedOut:
                SignInView()
            case .signedIn:
                // its own identity per account: the next account starts from Home, not on this one's open playlist
                content().id(account.user?.id)
                    // a new account's recovery codes, shown this once
                    .sheet(isPresented: Binding(get: { account.codesToShow != nil }, set: { if !$0 { account.codesToShow = nil } })) {
                        RecoveryCodesSheet(codes: account.codesToShow ?? [], username: account.user?.username ?? "") {
                            account.codesToShow = nil
                        }
                    }
            }
        }
        .task {
            // the server first: the stored token is checked with it, and signing in needs it
            await server.ensureRunning()
            await account.start()
            #if DEBUG
            if SelfTest.isRunning, account.state == .signedOut { await SelfTest.signUpTestAccount(account) }
            #endif
        }
    }
}

/// Sign in, or create an account (one switch between the two). Apple's sign-in sheets as the model (8 Oct): the app
/// icon, a title, two fields, one prominent button; no notes. The rules show only when broken: the server's reason
/// ("Wrong username or password", "That username is taken") is written to be shown. On the window's own surface,
/// see-through like the main window.
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(ServerLauncher.self) private var server
    @AppStorage("serverURL") private var serverURL = API.defaultServer
    @State private var editingServer = false
    @State private var serverDraft = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var device = Account.deviceName
    @State private var mode = Mode.signIn
    @State private var code = ""
    @State private var problem: String?
    @State private var working = false
    @State private var shakes = 0
    @FocusState private var focus: Field?
    private enum Field { case username, code, password, device, server }
    /// Sign in, create an account, or set a new password with a recovery code.
    private enum Mode { case signIn, create, recover }
    private var creating: Bool { mode == .create }

    private var ready: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working
            && (mode != .recover || code.filter(\.isLetter).count + code.filter(\.isNumber).count >= 16)
    }

    private var title: String {
        switch mode { case .signIn: "Sign In"; case .create: "Create Account"; case .recover: "Reset Password" }
    }

    private var actionLabel: String {
        switch mode {
        case .signIn: working ? "Signing In…" : "Sign In"
        case .create: working ? "Creating…" : "Create Account"
        case .recover: working ? "Resetting…" : "Reset Password"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text(title).textStyle(.title2, weight: .semibold)
                if let notice = account.notice, mode == .signIn {
                    Text(notice).textStyle(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = mode == .recover ? .code : .password }
                if mode == .recover {
                    TextField("Recovery Code", text: $code, prompt: Text("XXXX-XXXX-XXXX-XXXX"))
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .focused($focus, equals: .code)
                        .onSubmit { focus = .password }
                }
                SecureField(mode == .signIn ? "Password" : mode == .create ? "Password (8 or more characters)"
                                                                               : "New Password (8 or more characters)", text: $password)
                    .textContentType(mode == .signIn ? .password : .newPassword)
                    .focused($focus, equals: .password)
                    .onSubmit { go() }
                // what your other devices will call this Mac: shown, so you see what is sent, and yours to change
                HStack(spacing: 8) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    TextField("Device Name", text: $device)
                        .focused($focus, equals: .device)
                        .onSubmit { go() }
                }
                .help("The name this Mac has in your list of devices")
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .disabled(working)
            // [reduceMotion]: the animator's closure is Sendable; it takes the value, not the view's main-actor property
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { [reduceMotion] fields, x in
                fields.offset(x: reduceMotion ? 0 : x)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(-9, duration: 0.06)
                    SpringKeyframe(8, duration: 0.07)
                    SpringKeyframe(-6, duration: 0.07)
                    SpringKeyframe(0, duration: 0.1)
                }
            }
            if let problem {
                Text(problem)
                    .textStyle(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
            Button { go() } label: {
                // no spinner: text, nothing animating
                Text(actionLabel).frame(maxWidth: .infinity)
            }
            .compatGlassButton(prominent: true)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!ready)
            HStack(spacing: 14) {
                Button(mode == .signIn ? "Create Account…" : "Sign In Instead") { switchTo(mode == .signIn ? .create : .signIn) }
                if mode == .signIn {
                    Button("Forgot Password?") { switchTo(.recover) }
                }
            }
            .buttonStyle(.link)
            .disabled(working)
            // the server: yours to choose before signing in (8 Oct); Settings › Server changes it later. Opens by itself
            // when the server could not be reached (a wrong address would otherwise lock you out)
            if editingServer || account.unreachable {
                TextField("Server Address", text: $serverDraft, prompt: Text(API.defaultServer))
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .server)
                    .onAppear { serverDraft = serverURL }
                    .onSubmit { saveServer() }
            } else {
                Button("Server: \(Self.shortAddress(serverURL))") { editingServer = true }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                    .textStyle(.callout)
            }
        }
        .frame(width: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowSurface() }
        .animation(.snappy(duration: 0.2), value: problem)
        .animation(.snappy(duration: 0.2), value: mode)
        .sensoryFeedback(.error, trigger: shakes)
        .onAppear { focus = .username }
        .onChange(of: username) { problem = nil }
        .onChange(of: password) { problem = nil }
        .onChange(of: code) { problem = nil }
        // a pasted address is used once you click away, as any other field: Return alone saved it, so the button
        // signed in at the old address (14 Oct, #23)
        .onChange(of: focus) { old, _ in if old == .server { saveServer() } }
    }

    private func switchTo(_ next: Mode) {
        mode = next
        problem = nil
        password = ""
        focus = username.isEmpty ? .username : next == .recover ? .code : .password
    }

    /// The address the field holds, saved as Settings › Server saves it; a running local server is started if needed.
    /// Saved only when it changed: an unchanged one may be a test's launch-argument address, not yours (see Settings).
    /// True when it changed.
    @discardableResult private func saveServer() -> Bool {
        guard editingServer || account.unreachable else { return false }
        let typed = API.address(serverDraft)
        editingServer = false
        serverDraft = typed
        guard typed != serverURL else { return false }
        serverURL = typed
        problem = nil
        Task { await server.ensureRunning() }
        return true
    }

    /// "127.0.0.1:8000" rather than "http://127.0.0.1:8000"; the scheme shows only when it is not plain http.
    private static func shortAddress(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host() else { return address }
        let port = url.port.map { ":\($0)" } ?? ""
        return url.scheme == "https" ? "https://\(host)\(port)" : "\(host)\(port)"
    }

    private func go() {
        guard ready else { return }
        let moved = saveServer()        // the address in the field, even if Return was never pressed
        working = true
        problem = nil
        Task {
            if moved { await server.ensureRunning() }
            let name = username.trimmingCharacters(in: .whitespaces)
            let reason = mode == .recover
                ? await account.recover(name, code: code, newPassword: password, device: device)
                : await account.signIn(name, password, create: creating, device: device)
            working = false
            if let reason { problem = reason; shakes += 1 }
        }
    }
}
