import SwiftUI

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// The Settings window (⌘,), the Mac convention.
struct SettingsView: View {
    @AppStorage("serverURL") private var serverURL = API.defaultServer
    @AppStorage("appearance") private var appearance = Appearance.system
    @Environment(Presence.self) private var presence
    @State private var serverOK: Bool?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Toggle("Show what I'm listening to on Discord",
                       isOn: Binding(get: { presence.enabled }, set: { presence.setEnabled($0) }))
                TextField("Application ID", text: Binding(get: { presence.clientID }, set: { presence.setClientID($0) }),
                          prompt: Text("e.g. 1291000000000000000"))
                LabeledContent("Status") { Text(presence.status).foregroundStyle(.secondary) }
            } header: {
                Text("Discord")
            } footer: {
                Text("Needs the Discord desktop app running. Create an application at discord.com/developers → New Application, name it what you want people to see (\"Listening to …\"), and paste its Application ID here.")
                    .foregroundStyle(.secondary)
            }

            Section("Server") {
                TextField("Address", text: $serverURL)
                LabeledContent("Status") {
                    switch serverOK {
                    case .none: Text("Checking…").foregroundStyle(.secondary)
                    case .some(true): Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .some(false): Label("Not reachable", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: serverURL) {
            serverOK = nil
            serverOK = await API.health()
        }
    }
}
