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
                Text(server.state == .starting ? "Starting your server…" : "")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
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

/// One screen, two buttons: Sign In, or Create Account with the same name and password. The server's reason shows
/// as it comes ("Wrong username or password", "That username is taken"): it is written to be shown.
struct SignInView: View {
    @Environment(Account.self) private var account
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var username = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var working = false
    @State private var shakes = 0
    @FocusState private var focus: Field?
    private enum Field { case username, password }

    private var ready: Bool { !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("NoNonsense").textStyle(size: 30, weight: .bold)
            Text("Sign in to your library.").textStyle(.body).foregroundStyle(.secondary)
            if let notice = account.notice {
                Label(notice, systemImage: "person.crop.circle.badge.exclamationmark")
                    .textStyle(.callout, weight: .medium)
            }
            VStack(spacing: 10) {
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .onSubmit { go(create: false) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.title3)
            .disabled(working)
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { fields, x in
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
                Label(problem, systemImage: "exclamationmark.circle.fill")
                    .textStyle(.callout)
                    .foregroundStyle(.red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            HStack {
                Button("Create Account") { go(create: true) }
                    .buttonStyle(.glass)
                    .disabled(!ready)
                Spacer()
                Button(working ? "One moment…" : "Sign In") { go(create: false) }   // no spinner: text, nothing animating
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .controlSize(.large)
            Text("A new account: a name of 3–32 characters, a password of 8–64.")
                .textStyle(.caption).foregroundStyle(.secondary)
            // a wrong address would otherwise lock you out: Settings › Server is one click away
            SettingsLink { Text("Server: \(API.baseURL.absoluteString) · Change…") }
                .buttonStyle(.link)
                .textStyle(.caption)
        }
        .frame(width: 340)
        .padding(28)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .animation(.snappy(duration: 0.25), value: problem)
        .sensoryFeedback(.error, trigger: shakes)
        .onAppear { focus = .username }
        .onChange(of: username) { problem = nil }
        .onChange(of: password) { problem = nil }
    }

    private func go(create: Bool) {
        guard ready else { return }
        working = true
        problem = nil
        Task {
            let reason = await account.signIn(username.trimmingCharacters(in: .whitespaces), password, create: create)
            working = false
            if let reason { problem = reason; shakes += 1 }
        }
    }
}
