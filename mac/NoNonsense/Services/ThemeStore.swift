import AppKit
import Observation
import SwiftUI

/// Every coloured part of the app, and how its colour is chosen: the system's own, the playing song's, or yours.
/// Settings › Appearance edits it; the views ask `color(_:)`. Saved in UserDefaults ("theme.<element>.mode/.hex").
@Observable
final class ThemeStore {
    enum Mode: String, CaseIterable, Identifiable {
        case system, song, custom
        var id: String { rawValue }
        var label: String {
            switch self { case .system: "System"; case .song: "Song"; case .custom: "Custom" }
        }
    }

    enum Element: String, CaseIterable, Identifiable {
        case background, buttons, progress, volume, heart, playing, playerBar
        var id: String { rawValue }

        var title: String {
            switch self {
            case .background: "Background"
            case .buttons: "Buttons"
            case .progress: "Progress line"
            case .volume: "Volume"
            case .heart: "Heart"
            case .playing: "Playing song"
            case .playerBar: "Player bar"
            }
        }

        /// What "System" looks like, said once under the title.
        var detail: String {
            switch self {
            case .background: "The window's colour wash. System: none"
            case .buttons: "Play, Shuffle, selections. System: your Mac's accent"
            case .progress: "The line under the player. System: grey"
            case .volume: "The volume sliders. System: your Mac's accent"
            case .heart: "A liked song's heart. System: pink"
            case .playing: "The playing song's title and icon. System: your Mac's accent"
            case .playerBar: "The player's glass. System: clear"
            }
        }

        var defaultMode: Mode { self == .playerBar ? .system : .song }

        var defaultHex: String {
            switch self {
            case .background: "#5E5CE6"      // the system indigo
            case .heart: "#FF375F"           // the system pink
            case .playerBar: "#FFFFFF"
            default: "#0A84FF"               // the system blue
            }
        }
    }

    /// The playing cover's most vivid colour (nil for a grey cover): what "Song" means. RootView keeps it current.
    var songColor: Color?

    private var modes: [Element: Mode] = [:]
    private var hexes: [Element: String] = [:]

    init() {
        let defaults = UserDefaults.standard
        for element in Element.allCases {
            modes[element] = defaults.string(forKey: "theme.\(element.rawValue).mode").flatMap(Mode.init(rawValue:)) ?? element.defaultMode
            hexes[element] = defaults.string(forKey: "theme.\(element.rawValue).hex") ?? element.defaultHex
        }
    }

    func mode(_ element: Element) -> Mode { modes[element] ?? element.defaultMode }
    func hex(_ element: Element) -> String { hexes[element] ?? element.defaultHex }

    func setMode(_ mode: Mode, for element: Element) {
        modes[element] = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "theme.\(element.rawValue).mode")
    }

    func setHex(_ hex: String, for element: Element) {
        hexes[element] = hex
        UserDefaults.standard.set(hex, forKey: "theme.\(element.rawValue).hex")
    }

    /// The colour for an element; nil means "the system's own look" (each view knows what that is).
    func color(_ element: Element) -> Color? {
        switch mode(element) {
        case .system: nil
        case .song: songColor
        case .custom: Color(hex: hex(element))
        }
    }

    func setAll(_ mode: Mode) { Element.allCases.forEach { setMode(mode, for: $0) } }

    func reset() {
        for element in Element.allCases {
            setMode(element.defaultMode, for: element)
            setHex(element.defaultHex, for: element)
        }
    }
}
