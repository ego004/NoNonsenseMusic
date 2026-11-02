import SwiftUI

/// Settings › Lyrics: when the app asks the server for them, what they are translated into, and the experimental Genius
/// notes. The same choices and words as the Mac's.
struct LyricsSection: View {
    @AppStorage("lyricsFetch") private var fetch = "songStart"
    @AppStorage("translateInto") private var translateInto = ""         // LyricsTranslations.target: "" this device's own
    @AppStorage("geniusNotes") private var genius = false               // experimental, off by default

    var body: some View {
        Section {
            Picker("Load lyrics", selection: $fetch) {
                Text("Ahead of time").tag("songStart")
                Text("Only when I open Lyrics").tag("onOpen")
            }
        } header: {
            Text("Lyrics")
        } footer: {
            Text("Ahead of time loads them as a song starts, and the next song's too. Downloaded songs keep theirs offline.")
        }
        Section {
            Picker("Translate into", selection: $translateInto) {
                Text("System language").tag("")
                ForEach(LyricsTranslations.choices, id: \.id) { Text($0.name).tag($0.id) }
            }
        } footer: {
            Text("For Translate in Lyrics. This \(UIDevice.current.model) translates them (iOS asks to download a language the first time); what it can't goes to Google. The line under the translation says which.")
        }
        Section {
            Toggle(isOn: $genius) {
                Text("Genius notes")
                Text("Underlined lines show Genius annotations, and ⓘ shows About This Song. Adds one lookup per song.")
            }
        } header: {
            Text("Experimental")
        }
    }
}

/// Settings › Storage: the songs kept after you play them (they start at once and play offline), and the downloads.
struct StorageSection: View {
    @Environment(DownloadStore.self) private var downloads
    @AppStorage("audioCacheMB") private var cacheMB = AudioCache.defaultLimitMB
    @State private var used: Int?
    @State private var confirming = false

    var body: some View {
        Section {
            Picker("Keep songs on this \(UIDevice.current.model)", selection: $cacheMB) {
                Text("Off").tag(0)
                Text("250 MB").tag(250)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1000)
                Text("2 GB").tag(2000)
            }
            .onChange(of: cacheMB) { Task { await AudioCache.shared.evict(); used = await AudioCache.shared.size() } }
            LabeledContent("Used", value: used.map(Self.bytes) ?? "–")
                .task { used = await AudioCache.shared.size() }
            Button("Clear Kept Songs", role: .destructive) { confirming = true }
                .disabled((used ?? 0) == 0)
                .confirmationDialog("Clear the songs kept on this \(UIDevice.current.model)?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Clear", role: .destructive) {
                        Task { await AudioCache.shared.clear(); used = await AudioCache.shared.size() }
                    }
                } message: {
                    Text("They download again when you play them. Downloads are not touched.")
                }
            NavigationLink { DownloadsScreen() } label: {
                LabeledContent("Downloads", value: downloads.items.isEmpty ? "None" : "\(downloads.items.count) \(downloads.items.count == 1 ? "song" : "songs"), \(Self.bytes(downloads.totalBytes))")
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Songs you've played start at once and play offline. The least recently played are removed first.")
        }
    }

    private static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowsNonnumericFormatting = false            // "0 bytes", not "Zero KB"
        return formatter.string(fromByteCount: Int64(count))
    }
}

/// Settings › Account: who you are signed in as, this device's name, and the recovery codes (the way back in with a
/// forgotten password).
struct AccountDetailsSection: View {
    @Environment(Account.self) private var account
    @Environment(LibraryStore.self) private var library
    @State private var deviceDraft = Account.deviceName
    @State private var codesLeft: Int?
    @State private var askingPassword = false
    @State private var password = ""
    @State private var newCodes: [String]?

    var body: some View {
        Section {
            LabeledContent("Username", value: account.user?.username ?? "Not signed in")
            LabeledContent("Device name") {
                TextField("Device name", text: $deviceDraft)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit {
                        Task { if let problem = await account.renameDevice(deviceDraft) { library.notify(problem, symbol: "exclamationmark.triangle.fill") } }
                    }
            }
            LabeledContent("Unused recovery codes") {
                if let codesLeft { Text("\(codesLeft) of 10").foregroundStyle(codesLeft <= 3 ? .orange : .secondary) } else { Text("–").foregroundStyle(.secondary) }
            }
            .task(id: account.user?.id) { codesLeft = try? await API.recoveryCodesLeft() }
            Button("New Recovery Codes…") { password = ""; askingPassword = true }
                .alert("New Recovery Codes", isPresented: $askingPassword) {
                    SecureField("Password", text: $password)
                    Button("Cancel", role: .cancel) {}
                    Button("Make Codes") {
                        let typed = password
                        password = ""
                        Task {
                            switch await account.replaceRecoveryCodes(password: typed) {
                            case .success(let codes): newCodes = codes; codesLeft = codes.count
                            case .failure(let problem): library.notify(problem.text, symbol: "exclamationmark.triangle.fill")
                            }
                        }
                    }
                } message: {
                    Text("Your password makes ten new codes. The old ones stop working.")
                }
                .sheet(isPresented: Binding(get: { newCodes != nil }, set: { if !$0 { newCodes = nil } })) {
                    RecoveryCodesSheet(codes: newCodes ?? [], username: account.user?.username ?? "")
                }
        } header: {
            Text("You")
        }
    }
}

/// The new codes, shown once: copy them somewhere safe. Each resets the password once.
private struct RecoveryCodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let codes: [String]
    let username: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(codes, id: \.self) { code in
                        Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                } footer: {
                    Text("Each code resets your password once. They are not shown again.")
                }
            }
            .navigationTitle("Recovery Codes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(copied ? "Copied" : "Copy All") {
                        UIPasteboard.general.string = "NoNonsenseMusic recovery codes for \(username)\n" + codes.joined(separator: "\n")
                        copied = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .interactiveDismissDisabled()
    }
}
