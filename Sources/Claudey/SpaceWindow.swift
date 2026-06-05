import Cocoa
import SwiftTerm

// Container view that tiles its panes in a grid and re-lays on resize.
final class GridContainer: NSView {
    var panes: [NSView] = []
    let gap: CGFloat = 12

    override var isFlipped: Bool { true } // top-left origin → first pane top-left

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPanes() }
    override func layout() { super.layout(); layoutPanes() }

    func layoutPanes() {
        let n = panes.count
        guard n > 0, bounds.width > 1, bounds.height > 1 else { return }
        let cols = Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let cw = (bounds.width - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let ch = (bounds.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (i, p) in panes.enumerated() {
            let r = i / cols, c = i % cols
            p.frame = NSRect(x: gap + CGFloat(c) * (cw + gap),
                             y: gap + CGFloat(r) * (ch + gap),
                             width: cw, height: ch)
        }
    }
}

// A single Claudey window holding N terminal panes, each running `claude`.
// Glassy, minimalist, gray.
final class SpaceWindowController: NSWindowController, NSWindowDelegate {
    private let grid = GridContainer()
    private var terms: [LocalProcessTerminalView] = []
    var onClose: ((SpaceWindowController) -> Void)?

    convenience init(cwd: String, shellCmd: String, count: Int) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
                           styleMask: [.titled, .closable, .resizable,
                                       .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Claudey — \((cwd as NSString).lastPathComponent)"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .visible
        win.isMovableByWindowBackground = false
        win.minSize = NSSize(width: 540, height: 360)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = .clear

        self.init(window: win)
        win.delegate = self

        // Gray glass backing for the whole window.
        let blur = NSVisualEffectView(frame: win.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        win.contentView = blur

        grid.frame = blur.bounds
        grid.autoresizingMask = [.width, .height]
        blur.addSubview(grid)

        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        for _ in 0..<max(1, count) {
            let pane = makePane()
            grid.addSubview(pane.card)
            terms.append(pane.term)
            // Login shell so PATH has `claude`; run command, then keep shell open.
            pane.term.startProcess(executable: "/bin/zsh",
                                   args: ["-l", "-c", shellCmd + "; exec /bin/zsh -l"],
                                   environment: env,
                                   currentDirectory: cwd)
        }
        grid.panes = terms.indices.map { grid.subviews[$0] }
        grid.layoutPanes()
        win.center()
    }

    // One rounded translucent gray card wrapping a transparent terminal.
    private func makePane() -> (card: NSView, term: LocalProcessTerminalView) {
        let card = NSVisualEffectView(frame: .zero)
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.07).cgColor

        let term = LocalProcessTerminalView(frame: card.bounds)
        term.autoresizingMask = [.width, .height]
        // Slightly tinted so text stays readable while the gray glass shows through.
        term.nativeBackgroundColor = NSColor(white: 0.11, alpha: 0.55)
        term.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        term.wantsLayer = true
        term.layer?.isOpaque = false
        card.addSubview(term)
        return (card, term)
    }

    func show() {
        // Promote to a regular app (Dock icon + window focus) while a space is open;
        // reverts to accessory when the last one closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let first = terms.first { window?.makeFirstResponder(first) }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}
