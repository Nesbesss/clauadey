import Cocoa
import SwiftTerm

// Premium palette — near-black like Warp's default dark, warm Claude accent.
private enum Palette {
    static let windowTop = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)   // #0b0c0e
    static let windowBot = NSColor(srgbRed: 0.024, green: 0.027, blue: 0.031, alpha: 1)   // #060708
    static let pane      = NSColor(srgbRed: 0.043, green: 0.047, blue: 0.055, alpha: 1)   // #0b0c0e
    static let header    = NSColor(srgbRed: 0.063, green: 0.067, blue: 0.078, alpha: 1)   // #101114
    static let fg        = NSColor(srgbRed: 0.945, green: 0.945, blue: 0.945, alpha: 1)   // #f1f1f1
    static let muted     = NSColor(srgbRed: 0.49,  green: 0.53,  blue: 0.58,  alpha: 1)
    static let accent    = NSColor(srgbRed: 0.85,  green: 0.46,  blue: 0.34,  alpha: 1)   // #d97757
    static let border    = NSColor(white: 1, alpha: 0.07)
    static let sep       = NSColor(white: 1, alpha: 0.06)
}

// Warp default-dark 16-color ANSI palette (normal 0–7, bright 8–15).
private func warpAnsiPalette() -> [SwiftTerm.Color] {
    func c(_ r: Int, _ g: Int, _ b: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(r) * 257, green: UInt16(g) * 257, blue: UInt16(b) * 257)
    }
    return [
        c(0x61,0x61,0x61), c(0xff,0x82,0x72), c(0xb4,0xfa,0x72), c(0xfe,0xfd,0xc2),
        c(0xa5,0xd5,0xfe), c(0xff,0x8f,0xfd), c(0xd0,0xd1,0xfe), c(0xf1,0xf1,0xf1),
        c(0x8e,0x8e,0x8e), c(0xff,0xc4,0xbd), c(0xd6,0xfc,0xb9), c(0xfe,0xfd,0xd5),
        c(0xc1,0xe3,0xfe), c(0xff,0xb1,0xfe), c(0xe5,0xe6,0xfe), c(0xfe,0xff,0xff),
    ]
}

// Tiles panes in a grid; reserves space at top for the transparent titlebar.
final class GridContainer: NSView {
    var panes: [NSView] = []
    let gap: CGFloat = 14
    let topInset: CGFloat = 30

    override var isFlipped: Bool { true }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutPanes() }
    override func layout() { super.layout(); layoutPanes() }

    func layoutPanes() {
        let n = panes.count
        guard n > 0, bounds.width > 1, bounds.height > 1 else { return }
        let cols = Int(ceil(Double(n).squareRoot()))
        let rows = Int(ceil(Double(n) / Double(cols)))
        let availW = bounds.width
        let availH = bounds.height - topInset
        let cw = (availW - gap * CGFloat(cols + 1)) / CGFloat(cols)
        let ch = (availH - gap * CGFloat(rows + 1)) / CGFloat(rows)
        for (i, p) in panes.enumerated() {
            let r = i / cols, c = i % cols
            p.frame = NSRect(x: gap + CGFloat(c) * (cw + gap),
                             y: topInset + gap + CGFloat(r) * (ch + gap),
                             width: cw, height: ch)
        }
    }
}

// A single Claudey window holding N premium terminal panes running `claude`.
final class SpaceWindowController: NSWindowController, NSWindowDelegate {
    private let grid = GridContainer()
    private var terms: [LocalProcessTerminalView] = []
    private var cards: [NSView] = []
    private var clickMonitor: Any?
    var onClose: ((SpaceWindowController) -> Void)?

    convenience init(cwd: String, shellCmd: String, count: Int) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
                           styleMask: [.titled, .closable, .resizable,
                                       .miniaturizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Claudey"
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 560, height: 380)
        win.appearance = NSAppearance(named: .darkAqua)
        win.isOpaque = false
        win.backgroundColor = .clear

        self.init(window: win)
        win.delegate = self

        // Subtle translucency behind a deep slate gradient → premium, not busy.
        let blur = NSVisualEffectView(frame: win.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .underWindowBackground
        blur.blendingMode = .behindWindow
        blur.state = .active
        win.contentView = blur

        let tint = NSView(frame: blur.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        let grad = CAGradientLayer()
        grad.frame = blur.bounds
        grad.colors = [Palette.windowTop.cgColor, Palette.windowBot.cgColor]
        grad.startPoint = CGPoint(x: 0, y: 0)
        grad.endPoint = CGPoint(x: 1, y: 1)
        tint.layer = grad
        tint.layer?.opacity = 0.92
        blur.addSubview(tint)

        grid.frame = blur.bounds
        grid.autoresizingMask = [.width, .height]
        blur.addSubview(grid)

        let folder = (cwd as NSString).lastPathComponent
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        for _ in 0..<max(1, count) {
            let (card, term) = makePane(folder: folder)
            grid.addSubview(card)
            cards.append(card)
            terms.append(term)
            term.startProcess(executable: "/bin/zsh",
                              args: ["-l", "-c", shellCmd + "; exec /bin/zsh -l"],
                              environment: env,
                              currentDirectory: cwd)
        }
        grid.panes = cards
        grid.layoutPanes()
        win.center()

        // Active-pane accent ring: highlight the card under each click.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            self?.highlightPane(at: e)
            return e
        }
        highlightCard(cards.first)
    }

    private func highlightPane(at event: NSEvent) {
        guard event.window === window else { return }
        let p = grid.convert(event.locationInWindow, from: nil)
        if let hit = cards.first(where: { $0.frame.contains(p) }) { highlightCard(hit) }
    }

    private func highlightCard(_ active: NSView?) {
        for c in cards {
            let on = c === active
            c.layer?.borderColor = (on ? Palette.accent.withAlphaComponent(0.75)
                                       : Palette.border).cgColor
            c.layer?.borderWidth = on ? 1.6 : 1
        }
    }

    // Rounded slate card: header (folder label) + padded terminal, with depth.
    private func makePane(folder: String) -> (card: NSView, term: LocalProcessTerminalView) {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Palette.border.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.40
        card.layer?.shadowRadius = 18
        card.layer?.shadowOffset = CGSize(width: 0, height: -5)

        // Clipped inner so rounded corners hold while the card casts a shadow.
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 14
        clip.layer?.masksToBounds = true
        clip.layer?.backgroundColor = Palette.pane.cgColor
        clip.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(clip)

        // Header strip: accent dot + folder name, with a hairline separator.
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = Palette.header.cgColor
        header.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(header)

        let sep = NSView()
        sep.wantsLayer = true
        sep.layer?.backgroundColor = Palette.sep.cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(sep)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = Palette.accent.cgColor
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(dot)

        let label = NSTextField(labelWithString: folder.isEmpty ? "claude" : folder)
        label.font = NSFont(name: "SFMono-Medium", size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = Palette.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(label)

        let term = LocalProcessTerminalView(frame: .zero)
        term.nativeBackgroundColor = Palette.pane
        term.nativeForegroundColor = Palette.fg
        term.caretColor = Palette.accent
        term.selectedTextBackgroundColor = Palette.accent.withAlphaComponent(0.30)
        term.font = NSFont(name: "SFMono-Regular", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        term.installColors(warpAnsiPalette()) // Warp's exact ANSI colors
        term.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(term)

        NSLayoutConstraint.activate([
            clip.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            clip.topAnchor.constraint(equalTo: card.topAnchor),
            clip.bottomAnchor.constraint(equalTo: card.bottomAnchor),

            header.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            header.topAnchor.constraint(equalTo: clip.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 28),

            sep.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            sep.topAnchor.constraint(equalTo: header.bottomAnchor),
            sep.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            term.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 12),
            term.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -12),
            term.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            term.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -10),
        ])
        return (card, term)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if let first = terms.first { window?.makeFirstResponder(first) }
    }

    func windowWillClose(_ notification: Notification) {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        onClose?(self)
    }
}
