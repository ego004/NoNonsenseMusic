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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var device = Account.deviceName
    @State private var creating = false
    @State private var problem: String?
    @State private var working = false
    @State private var shakes = 0
    @FocusState private var focus: Field?
    private enum Field { case username, password, device }

    private var ready: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text(creating ? "Create Account" : "Sign In").textStyle(.title2, weight: .semibold)
                if let notice = account.notice, !creating {
                    Text(notice).textStyle(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 8) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField(creating ? "Password (8 or more characters)" : "Password", text: $password)
                    .textContentType(creating ? .newPassword : .password)
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
                Text(working ? (creating ? "Creating…" : "Signing In…") : (creating ? "Create Account" : "Sign In"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!ready)
            Button(creating ? "Sign In Instead" : "Create Account…") {
                creating.toggle()
                problem = nil
            }
            .buttonStyle(.link)
            .disabled(working)
            // a wrong address would lock you out: offered only when the server could not be reached
            if account.unreachable {
                SettingsLink { Text("Server Settings…") }
                    .buttonStyle(.link)
            }
        }
        .frame(width: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { WindowSurface() }
        .animation(.snappy(duration: 0.2), value: problem)
        .animation(.snappy(duration: 0.2), value: creating)
        .sensoryFeedback(.error, trigger: shakes)
        .onAppear { focus = .username }
        .onChange(of: username) { problem = nil }
        .onChange(of: password) { problem = nil }
    }

    private func go() {
        guard ready else { return }
        working = true
        problem = nil
        Task {
            let reason = await account.signIn(username.trimmingCharacters(in: .whitespaces), password, create: creating, device: device)
            working = false
            if let reason { problem = reason; shakes += 1 }
        }
    }
}
