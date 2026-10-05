#if DEBUG
import AppKit

/// Debug builds only, and only when started with `NN_SELFTEST=<folder>`:
/// draws the main window into `<folder>/window.png`, reports which view a click on each sidebar row would reach,
/// clicks the second row, then quits. Lets layout and click problems be checked without screen recording permission
/// (the app draws its own window; nothing else on screen is captured).
///
///     NN_SELFTEST=/tmp/nn mac/build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense
enum SelfTest {
    private static var started = false

    static func runIfAsked() {
        guard !started, let folder = ProcessInfo.processInfo.environment["NN_SELFTEST"] else { return }
        started = true
        Task {
            try? await Task.sleep(for: .seconds(4))       // let the window lay out and the first requests finish
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let frame = window.contentView?.superview else { report("no window"); NSApp.terminate(nil); return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            report("window \(window.frame.size), key: \(window.isKeyWindow)")
            snapshot(frame, to: URL(filePath: folder).appending(path: "window.png"))

            // the sidebar List is an NSTableView underneath; ask AppKit which view a click on each row would reach
            let tables = descendants(of: frame).compactMap { $0 as? NSTableView }
            for table in tables {
                report("table: \(table.numberOfRows) rows, frame in window \(table.convert(table.bounds, to: nil))")
                for row in 0..<table.numberOfRows {
                    let p = center(of: table.convert(table.rect(ofRow: row), to: nil))
                    let hit = frame.hitTest(p)     // the frame view has no superview, so window coordinates
                    report("row \(row) at \(p): click reaches \(describe(hit)); inside the table: \(hit?.isDescendant(of: table) ?? false)")
                }
            }

            // a real click on the second row, through the normal event queue
            if let table = tables.first, table.numberOfRows > 1 {
                let p = center(of: table.convert(table.rect(ofRow: 1), to: nil))
                let before = table.selectedRow
                // a background window takes its first click only to come forward, so click twice when not in front
                let clicks = window.isKeyWindow ? 1 : 2
                for type in Array(repeating: [NSEvent.EventType.leftMouseDown, .leftMouseUp], count: clicks).flatMap({ $0 }) {
                    if let event = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
                report("clicked row 1: selected row \(before) -> \(table.selectedRow)")
                snapshot(frame, to: URL(filePath: folder).appending(path: "after-click.png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func report(_ line: String) { print("SELFTEST", line) }

    private static func center(of r: NSRect) -> NSPoint { NSPoint(x: r.midX, y: r.midY) }

    private static func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// "ClassName < Parent < Grandparent": enough to tell the sidebar from the detail column
    private static func describe(_ view: NSView?) -> String {
        var names: [String] = []
        var v = view
        while let current = v, names.count < 5 { names.append(String(describing: type(of: current))); v = current.superview }
        return names.isEmpty ? "nothing" : names.joined(separator: " < ")
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        report("wrote \(url.path)")
    }
}
#endif
