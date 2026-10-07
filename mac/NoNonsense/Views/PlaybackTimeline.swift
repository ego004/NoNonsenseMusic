import AppKit
import SwiftUI

/// The progress line with the time on each side: "1:12 ━━━━━○──── -2:33". Drawn by Core Animation, not SwiftUI.
///
/// Why: a SwiftUI progress bar has to be redrawn by the app for every change, and the old one changed twice a second
/// from a timer, redrawing the player bar each time: the app's biggest steady cost while playing (7 Oct). Here the
/// line is one animation from where the song is to its end, set up once and played by macOS's render server
/// (smooth, and nothing in the app per frame); the times change once a second, on the second, only while the window
/// can be seen. The view is set up again only when something really changes: play, pause, a seek, a new song.
struct PlaybackTimeline: View {
    var thickness: CGFloat = 3
    var textStyle: Font.TextStyle = .caption2
    var timesBelow = false                                    // Now Playing: the line full width, the times under its ends
    /// The player bar's: Now Playing covers it, and its blur re-blurs the whole window whenever anything under it
    /// changes. So while Now Playing is open, this line holds still and its times stop (nobody can see them).
    var underNowPlaying = false
    @Environment(Player.self) private var player
    @Environment(ThemeStore.self) private var theme
    @Environment(\.textScale) private var textScale
    @AppStorage("haptics") private var haptics = true
    @State private var hovering = false
    @State private var dragged: Double?                       // seconds, while you drag

    var body: some View {
        let fontSize = textStyle.macPointSize * textScale
        let labelWidth = (fontSize * 3.6).rounded(.up)          // "-10:00" in monospaced digits
        // (showNowPlaying is read only by the bar's line: Now Playing's own line must not observe it)
        let covered = underNowPlaying && player.showNowPlaying
        TimelineLayers(position: player.position,
                       running: player.isPlaying && !player.isBuffering && dragged == nil && !covered,
                       duration: player.duration,
                       dragged: dragged,
                       thickness: hovering || dragged != nil ? thickness * 2 : thickness,
                       fontSize: fontSize,
                       labelWidth: labelWidth,
                       timesBelow: timesBelow,
                       fill: NSColor(theme.color(.progress) ?? Color.primary.opacity(0.7)),
                       now: { [player] in player.livePosition })
            .frame(height: timesBelow ? 14 + fontSize * 1.5 : max(14, fontSize * 1.4))
            .overlay {
                // the drag area: the line (between the two times, or the full width above them)
                GeometryReader { geo in
                    let track = timesBelow ? geo.size.width : max(1, geo.size.width - 2 * (labelWidth + 8))
                    Color.clear
                        .contentShape(.rect)
                        .frame(width: track, height: timesBelow ? 14 : geo.size.height)
                        .position(x: geo.size.width / 2, y: timesBelow ? 7 : geo.size.height / 2)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let x = value.location.x
                                dragged = max(0, min(1, x / track)) * player.duration
                            }
                            .onEnded { _ in
                                if let d = dragged { player.seek(to: d) }
                                dragged = nil
                            })
                        .onHover { hovering = $0 }
                }
            }
            // while scrubbing: a tick each time the drag crosses a whole minute
            .sensoryFeedback(.alignment, trigger: dragged.map { Int($0 / 60) }) { _, _ in haptics && dragged != nil }
            .accessibilityElement()
            .accessibilityLabel("Progress")
            .accessibilityValue("\(formatTime(player.livePosition)) of \(formatTime(player.duration))")
    }
}

private struct TimelineLayers: NSViewRepresentable {
    let position: Double
    let running: Bool
    let duration: Double
    let dragged: Double?
    let thickness: CGFloat
    let fontSize: CGFloat
    let labelWidth: CGFloat
    let timesBelow: Bool
    let fill: NSColor
    let now: () -> Double

    func makeNSView(context: Context) -> TimelineLayersView { TimelineLayersView() }

    func updateNSView(_ view: TimelineLayersView, context: Context) {
        view.configure(running: running, duration: duration, shown: dragged, thickness: thickness, fontSize: fontSize,
                       labelWidth: labelWidth, timesBelow: timesBelow, fill: fill, now: now)
    }
}

/// The layers: the track, the played part (one scale animation to the end while playing) and two text layers.
final class TimelineLayersView: NSView {
    private let track = CALayer()
    private let played = CALayer()
    private let elapsed = CATextLayer()
    private let remaining = CATextLayer()
    private var timer: Timer?
    private var running = false
    private var duration = 0.0
    private var shown: Double?                                 // a fixed time to show (dragging), or nil: now
    private var thickness: CGFloat = 3
    private var fontSize: CGFloat = 10
    private var labelWidth: CGFloat = 36
    private var timesBelow = false
    private var fill = NSColor.labelColor
    private var now: () -> Double = { 0 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for layer in [track, played] { layer.masksToBounds = true }
        played.anchorPoint = CGPoint(x: 0, y: 0.5)              // grows from the left
        elapsed.alignmentMode = .right
        remaining.alignmentMode = .left
        for layer in [track, played, elapsed, remaining] { layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()] }
        [track, played, elapsed, remaining].forEach { layer?.addSublayer($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    isolated deinit { timer?.invalidate() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // SwiftUI's overlay takes the clicks and drags

    func configure(running: Bool, duration: Double, shown: Double?, thickness: CGFloat, fontSize: CGFloat,
                   labelWidth: CGFloat, timesBelow: Bool, fill: NSColor, now: @escaping () -> Double) {
        let restyled = fontSize != self.fontSize || fill != self.fill || thickness != self.thickness || labelWidth != self.labelWidth
            || timesBelow != self.timesBelow
        self.running = running; self.duration = duration; self.shown = shown; self.now = now
        self.thickness = thickness; self.fontSize = fontSize; self.labelWidth = labelWidth; self.timesBelow = timesBelow; self.fill = fill
        if restyled { needsLayout = true }
        restart()
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let width = bounds.width
        // AppKit layers count y from the bottom: in "below" mode the line sits 7 pt from the top
        let mid = timesBelow ? bounds.height - 7 : bounds.midY
        let lineX = timesBelow ? 0 : labelWidth + 8, lineWidth = max(1, width - 2 * lineX)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        track.frame = CGRect(x: lineX, y: mid - thickness / 2, width: lineWidth, height: thickness)
        track.cornerRadius = thickness / 2
        played.bounds = CGRect(x: 0, y: 0, width: lineWidth, height: thickness)
        played.position = CGPoint(x: lineX, y: mid)
        played.cornerRadius = thickness / 2
        let textY = timesBelow ? 0 : mid - fontSize * 0.62
        elapsed.alignmentMode = timesBelow ? .left : .right
        remaining.alignmentMode = timesBelow ? .right : .left
        for (layer, x) in [(elapsed, 0.0), (remaining, width - labelWidth)] {
            layer.frame = CGRect(x: x, y: textY, width: labelWidth, height: fontSize * 1.3)
            layer.contentsScale = scale
        }
        colours()
        CATransaction.commit()
        restart()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colours(); setTimes()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        restart()
    }

    @objc private func visibilityChanged(_ note: Notification) {
        guard (note.object as? NSWindow) === window else { return }
        restart()
    }

    private var visible: Bool { window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor }

    /// Where the song is now, as a fraction, and the played part animated from there to the end (or held still).
    private func restart() {
        timer?.invalidate(); timer = nil
        let time = shown ?? now()
        let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        played.removeAnimation(forKey: "progress")
        played.transform = CATransform3DMakeScale(fraction, 1, 1)
        if running && shown == nil && duration > time {
            let grow = CABasicAnimation(keyPath: "transform.scale.x")
            grow.fromValue = fraction
            grow.toValue = 1.0
            grow.duration = duration - time
            grow.timingFunction = CAMediaTimingFunction(name: .linear)
            grow.isRemovedOnCompletion = false
            grow.fillMode = .forwards
            // the line moves 1–5 pt a second: 10 frames a second is under a pixel a frame. Uncapped, macOS drew it at the
            // screen's full rate, 120 a second on a ProMotion display, for a change nobody can see (audit, 7 Oct)
            grow.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 15, preferred: 10)
            played.add(grow, forKey: "progress")
        }
        CATransaction.commit()
        setTimes()
        scheduleTimes()
    }

    /// Only the text, every second: the line animates by itself.
    private func restartTimes() {
        setTimes()
        scheduleTimes()
    }

    /// The next change of the times: once a second, on the second, only while they can be seen.
    private func scheduleTimes() {
        timer = nil
        guard running, shown == nil, visible else { return }
        let next = Timer(timeInterval: 1 - now().truncatingRemainder(dividingBy: 1) + 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartTimes() }
        }
        next.tolerance = 0.05                                    // lets macOS group wake-ups
        // .common: the times keep counting while you scroll or drag (a plain scheduled timer waited until you let go)
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func setTimes() {
        let time = max(0, shown ?? now())
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let colour = resolved(.secondaryLabelColor)
        func text(_ s: String) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour]) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        elapsed.string = text(formatTime(time))
        remaining.string = text("-" + formatTime(max(0, duration - time)))
        CATransaction.commit()
    }

    #if DEBUG
    /// Self-tests: is the played part animating, and what does the elapsed time say
    var debugState: (animating: Bool, elapsed: String) {
        (played.animation(forKey: "progress") != nil, (elapsed.string as? NSAttributedString)?.string ?? "")
    }
    #endif

    private func colours() {
        track.backgroundColor = resolved(NSColor.labelColor.withAlphaComponent(0.12)).cgColor
        played.backgroundColor = resolved(fill).cgColor
    }

    /// A dynamic colour (it differs in light and dark) as it looks in this view now.
    private func resolved(_ colour: NSColor) -> NSColor {
        var out = colour
        effectiveAppearance.performAsCurrentDrawingAppearance { out = NSColor(cgColor: colour.cgColor) ?? colour }
        return out
    }
}
