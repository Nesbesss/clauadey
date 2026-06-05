import Cocoa
import ImageIO
import UniformTypeIdentifiers

// Main folder opened on normal (left) click.
let MAIN_FOLDER = NSHomeDirectory()
let ICON_SIZE: CGFloat = 26

let HISTORY_KEY = "recentFolders"
let HISTORY_MAX = 12
let LOGO_KEY = "customLogoPath"
let TERMINALS_KEY = "terminalsPerClick"
let CAVEMAN_KEY = "autoInstallCaveman"
let TILE_KEY = "tileTerminals"
let SPACE_OPACITY_KEY = "spaceOpacity"   // 0.0–1.0
let SPACE_TINT_KEY = "spaceTint"         // hex "RRGGBB"
let SPACE_OPACITY_DEFAULT = 0.59
let SPACE_TINT_DEFAULT = "0d0e12"
let SESSIONS_MAX = 15

// Caveman plugin (https://github.com/JuliusBrussee/caveman). Auto-installed on
// launch when enabled, so a fresh machine gets it without manual setup.
let CAVEMAN_REPO = "JuliusBrussee/caveman"
let CAVEMAN_PLUGIN = "caveman@caveman"

// One past Claude Code session on disk.
struct SessionInfo {
    let uuid: String
    let cwd: String
    let label: String
    let mtime: Date
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var frames: [NSImage] = []
    var delays: [Double] = []
    var frameIndex = 0
    var timer: Timer?

    // Settings window refs.
    var settingsWindow: NSWindow?
    var logoPreview: NSImageView?
    var terminalsStepper: NSStepper?
    var terminalsValueLabel: NSTextField?
    var terminalsInfoLabel: NSTextField?
    var cavemanCheckbox: NSButton?
    var tileCheckbox: NSButton?
    var spaceOpacitySlider: NSSlider?
    var spaceOpacityLabel: NSTextField?
    var spaceTintWell: NSColorWell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            TERMINALS_KEY: 1, CAVEMAN_KEY: true, TILE_KEY: true,
            SPACE_OPACITY_KEY: SPACE_OPACITY_DEFAULT, SPACE_TINT_KEY: SPACE_TINT_DEFAULT,
        ])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "🤖" // fallback until frames load
            button.toolTip = "Left-click: Claude Code in main folder. Right-click: menu."
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        reloadIcon()
    }

    // MARK: - Icon

    func currentLogoPath() -> String {
        if let p = UserDefaults.standard.string(forKey: LOGO_KEY),
           FileManager.default.fileExists(atPath: p) {
            return p
        }
        return Bundle.main.path(forResource: "claude", ofType: "gif") ?? ""
    }

    func reloadIcon() {
        timer?.invalidate(); timer = nil
        frames = []; delays = []; frameIndex = 0
        loadFrames(from: currentLogoPath())
        if frames.isEmpty {
            statusItem.button?.image = nil
            statusItem.button?.title = "🤖"
        } else {
            startAnimating()
        }
    }

    func loadFrames(from path: String) {
        let (f, d) = renderFrames(from: path, size: ICON_SIZE)
        frames = f; delays = d
    }

    // Render every GIF frame, auto-cropped to content and fitted into a `size`
    // square preserving aspect. Reused for the menubar icon and the Dock icon.
    func renderFrames(from path: String, size: CGFloat) -> ([NSImage], [Double]) {
        guard !path.isEmpty,
              let data = NSData(contentsOfFile: path),
              let src = CGImageSourceCreateWithData(data, nil) else { return ([], []) }
        let count = CGImageSourceGetCount(src)

        var cgs: [CGImage] = []
        var rawDelays: [Double] = []
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            cgs.append(cg)
            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
               let gif = props[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                if let d = gif[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double, d > 0 {
                    delay = d
                } else if let d = gif[kCGImagePropertyGIFDelayTime as String] as? Double, d > 0 {
                    delay = d
                }
            }
            rawDelays.append(delay < 0.02 ? 0.1 : delay)
        }
        guard !cgs.isEmpty else { return ([], []) }

        let crop = contentBBox(cgs)
        var outFrames: [NSImage] = []
        for cg in cgs {
            let cropped = cg.cropping(to: crop) ?? cg
            let cw = CGFloat(cropped.width), ch = CGFloat(cropped.height)
            let scale = min(size / cw, size / ch)
            let dw = cw * scale, dh = ch * scale
            let dest = CGRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh)

            let img = NSImage(size: NSSize(width: size, height: size))
            img.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .high
            NSGraphicsContext.current?.cgContext.draw(cropped, in: dest)
            img.unlockFocus()
            img.isTemplate = false
            outFrames.append(img)
        }
        return (outFrames, rawDelays)
    }

    // Union of non-transparent bounding boxes across frames, in top-left pixel
    // coords (CGImage cropping space). Falls back to the full frame if opaque.
    func contentBBox(_ cgs: [CGImage]) -> CGRect {
        let w = cgs[0].width, h = cgs[0].height
        let bpr = w * 4
        var buf = [UInt8](repeating: 0, count: bpr * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        var minX = w, minY = h, maxX = -1, maxY = -1

        for cg in cgs where cg.width == w && cg.height == h {
            buf.withUnsafeMutableBytes { ptr in
                guard let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: bpr, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for y in 0..<h {
                let row = y * bpr
                for x in 0..<w where buf[row + x * 4 + 3] > 16 {
                    if x < minX { minX = x }; if x > maxX { maxX = x }
                    if y < minY { minY = y }; if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= 0 else { return CGRect(x: 0, y: 0, width: w, height: h) }

        // Buffer is bottom-up (CG origin); flip Y for top-left cropping space.
        let tlMinY = h - 1 - maxY, tlMaxY = h - 1 - minY
        let pad = 2
        let rx = max(0, minX - pad), ry = max(0, tlMinY - pad)
        let rX = min(w - 1, maxX + pad), rY = min(h - 1, tlMaxY + pad)
        return CGRect(x: rx, y: ry, width: rX - rx + 1, height: rY - ry + 1)
    }

    func startAnimating() {
        guard !frames.isEmpty else { return }
        statusItem.button?.title = ""
        showFrame()
    }

    func showFrame() {
        guard !frames.isEmpty else { return }
        statusItem.button?.image = frames[frameIndex]
        let delay = delays[frameIndex]
        frameIndex = (frameIndex + 1) % frames.count
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showFrame()
        }
    }

    // MARK: - Click handling

    @objc func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu(sender)
        } else {
            openClaude(at: MAIN_FOLDER)
        }
    }

    func showMenu(_ button: NSStatusBarButton) {
        let menu = buildMenu()
        // On macOS 26 the menu renders with Liquid Glass automatically.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claudey", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let main = NSMenuItem(title: "Open Main Folder",
                              action: #selector(openMain), keyEquivalent: "")
        main.target = self
        menu.addItem(main)

        let pick = NSMenuItem(title: "Open Folder…",
                              action: #selector(openPicker), keyEquivalent: "o")
        pick.target = self
        menu.addItem(pick)

        let hist = UserDefaults.standard.stringArray(forKey: HISTORY_KEY) ?? []
        if !hist.isEmpty {
            menu.addItem(.separator())
            let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            recent.isEnabled = false
            menu.addItem(recent)
            for path in hist {
                let item = NSMenuItem(title: (path as NSString).abbreviatingWithTildeInPath,
                                      action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = path
                item.toolTip = path
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History",
                                   action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        let sessions = recentSessions()
        if !sessions.isEmpty {
            menu.addItem(.separator())
            let parent = NSMenuItem(title: "Resume Session", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in sessions {
                let folder = (s.cwd as NSString).lastPathComponent
                var title = folder.isEmpty ? s.uuid : folder
                if !s.label.isEmpty { title += ": \(s.label)" }
                title += "  ·  \(relTime(s.mtime))"
                let item = NSMenuItem(title: title,
                                      action: #selector(resumeSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["uuid": s.uuid, "cwd": s.cwd]
                item.toolTip = "\(s.cwd)\n\(s.uuid)"
                sub.addItem(item)
            }
            menu.setSubmenu(sub, for: parent)
            menu.addItem(parent)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc func openMain() { openClaude(at: MAIN_FOLDER) }
    @objc func openPicker() { pickFolderThenOpen() }
    @objc func openRecent(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { openClaude(at: path) }
    }
    @objc func clearHistory() { UserDefaults.standard.removeObject(forKey: HISTORY_KEY) }
    @objc func quit() { NSApp.terminate(nil) }

    func recordFolder(_ path: String) {
        var hist = UserDefaults.standard.stringArray(forKey: HISTORY_KEY) ?? []
        hist.removeAll { $0 == path }
        hist.insert(path, at: 0)
        if hist.count > HISTORY_MAX { hist = Array(hist.prefix(HISTORY_MAX)) }
        UserDefaults.standard.set(hist, forKey: HISTORY_KEY)
    }

    func pickFolderThenOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Claude Code Here"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            openClaude(at: url.path)
        }
    }

    func openClaude(at path: String) {
        recordFolder(path)
        // Single-quote the path for the shell so $(...) / backticks / spaces in a
        // folder name cannot be interpreted as commands. ' -> '\'' .
        let shellPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let baseCmd = "cd '\(shellPath)' && claude"
        let fullCmd = cavemanGuard() + baseCmd
        let n = max(1, UserDefaults.standard.integer(forKey: TERMINALS_KEY))
        let useSpace = n > 1 && UserDefaults.standard.bool(forKey: TILE_KEY)
        if useSpace {
            // 2+ terminals → one Claudey window with N live panes.
            openSpace(cwd: path, shellCmd: fullCmd, count: n)
        } else {
            // 1 terminal (or space disabled) → Terminal.app window(s).
            runInTerminalApp(fullCmd, windows: n)
        }
    }

    // Build the one-time Caveman install guard, or "" when disabled / already done.
    // Checks the plugin cache dir; only installs if missing, so repeat launches are
    // a no-op. Output is silenced; a short notice prints while it runs.
    func cavemanGuard() -> String {
        guard UserDefaults.standard.bool(forKey: CAVEMAN_KEY) else { return "" }
        return "if [ ! -d \"$HOME/.claude/plugins/cache/caveman\" ]; then "
            + "echo 'Installing Caveman plugin (first run)…'; "
            + "claude plugin marketplace add \(CAVEMAN_REPO) >/dev/null 2>&1; "
            + "claude plugin install \(CAVEMAN_PLUGIN) >/dev/null 2>&1; "
            + "fi ; "
    }

    // Spawn `shellCmd` in `windows` new Terminal.app windows. `shellCmd` already
    // includes any Caveman guard.
    func runInTerminalApp(_ shellCmd: String, windows: Int) {
        // Escape for embedding inside an AppleScript double-quoted string.
        // Backslash first, then double quote.
        let asArg = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let n = max(1, windows)
        var source = "tell application \"Terminal\"\nactivate\n"
        for _ in 0..<n {
            // No `in` target = a NEW window each time.
            source += "do script \"\(asArg)\"\n"
        }
        source += "end tell"

        var error: NSDictionary?
        if let apple = NSAppleScript(source: source) {
            apple.executeAndReturnError(&error)
        }
        if let error = error {
            NSLog("AppleScript error: \(error)")
        }
    }

    // MARK: - Space (Rust multi-terminal window)

    // Launch the bundled `claudey-space` Rust binary: one window of N premium
    // terminal panes. Falls back to N Terminal.app windows if the binary is missing.
    func openSpace(cwd: String, shellCmd: String, count: Int) {
        guard let bin = Bundle.main.path(forResource: "claudey-space", ofType: nil) else {
            runInTerminalApp(shellCmd, windows: count)
            return
        }
        let opacity = UserDefaults.standard.object(forKey: SPACE_OPACITY_KEY) as? Double ?? SPACE_OPACITY_DEFAULT
        let tint = UserDefaults.standard.string(forKey: SPACE_TINT_KEY) ?? SPACE_TINT_DEFAULT
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--cwd", cwd, "--count", "\(count)", "--cmd", shellCmd,
                       "--title", "Claudey", "--icon", currentLogoPath(),
                       "--opacity", String(format: "%.3f", opacity), "--tint", tint]
        p.environment = ProcessInfo.processInfo.environment
        do {
            try p.run()
        } catch {
            NSLog("claudey-space launch failed: \(error)")
            runInTerminalApp(shellCmd, windows: count)
        }
    }

    // MARK: - Sessions

    @objc func resumeSession(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let uuid = info["uuid"], let cwd = info["cwd"] else { return }
        let shellPath = cwd.replacingOccurrences(of: "'", with: "'\\''")
        let shellUuid = uuid.replacingOccurrences(of: "'", with: "'\\''")
        // Resume always uses a single window regardless of terminals-per-click.
        let shellCmd = "cd '\(shellPath)' && claude --resume '\(shellUuid)'"
        runInTerminalApp(cavemanGuard() + shellCmd, windows: 1)
    }

    // Scan ~/.claude/projects/*/*.jsonl, newest first, up to SESSIONS_MAX.
    func recentSessions() -> [SessionInfo] {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        guard let projDirs = try? fm.contentsOfDirectory(atPath: base) else { return [] }

        var files: [(path: String, mtime: Date)] = []
        for d in projDirs {
            let dir = (base as NSString).appendingPathComponent(d)
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for it in items where it.hasSuffix(".jsonl") {
                let p = (dir as NSString).appendingPathComponent(it)
                let attrs = try? fm.attributesOfItem(atPath: p)
                let m = (attrs?[.modificationDate] as? Date) ?? .distantPast
                files.append((p, m))
            }
        }
        files.sort { $0.mtime > $1.mtime }

        var out: [SessionInfo] = []
        for f in files.prefix(SESSIONS_MAX) {
            let uuid = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let (cwd, label) = parseSession(f.path)
            out.append(SessionInfo(uuid: uuid, cwd: cwd, label: label, mtime: f.mtime))
        }
        return out
    }

    // Read the head of a session file to recover its cwd + first user prompt.
    func parseSession(_ path: String) -> (cwd: String, label: String) {
        var cwd = ""
        var label = ""
        guard let fh = FileHandle(forReadingAtPath: path) else { return (cwd, label) }
        let data = fh.readData(ofLength: 65536) // cwd + first prompt land early
        try? fh.close()
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let ld = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: ld) as? [String: Any]
            else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if label.isEmpty, (obj["type"] as? String) == "user",
               let t = extractUserText(obj) {
                let clean = cleanPrompt(t)
                if !clean.isEmpty { label = clean }
            }
            if !cwd.isEmpty && !label.isEmpty { break }
        }
        return (cwd, label)
    }

    func extractUserText(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] {
            for p in arr where (p["type"] as? String) == "text" {
                if let t = p["text"] as? String { return t }
            }
        }
        return nil
    }

    // Strip XML-ish command/caveat tags, collapse whitespace, cap length.
    func cleanPrompt(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count > 48 { t = String(t.prefix(48)) + "…" }
        return t
    }

    func relTime(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        return "\(Int(s / 86400))d ago"
    }

    // MARK: - Settings

    func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Claudey", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @objc func openSettings() {
        if settingsWindow == nil { buildSettingsWindow() }
        refreshSettingsUI()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func buildSettingsWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                           styleMask: [.titled, .closable],
                           backing: .buffered, defer: false)
        win.title = "Claudey Settings"
        win.isReleasedWhenClosed = false
        let content = win.contentView!

        func label(_ text: String, _ frame: NSRect, bold: Bool = false) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.frame = frame
            if bold { l.font = NSFont.boldSystemFont(ofSize: 13) }
            content.addSubview(l)
            return l
        }
        func note(_ text: String, _ frame: NSRect) -> NSTextField {
            let l = label(text, frame)
            l.font = NSFont.systemFont(ofSize: 11); l.textColor = .secondaryLabelColor
            l.maximumNumberOfLines = 3; l.lineBreakMode = .byWordWrapping
            return l
        }

        // --- Logo ---
        _ = label("Logo", NSRect(x: 20, y: 560, width: 200, height: 20), bold: true)

        let preview = NSImageView(frame: NSRect(x: 20, y: 485, width: 64, height: 64))
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 8
        content.addSubview(preview)
        logoPreview = preview

        let chooseBtn = NSButton(title: "Choose Image…", target: self, action: #selector(chooseLogo))
        chooseBtn.frame = NSRect(x: 100, y: 517, width: 150, height: 28)
        chooseBtn.bezelStyle = .rounded
        content.addSubview(chooseBtn)

        let resetBtn = NSButton(title: "Reset to Default", target: self, action: #selector(resetLogo))
        resetBtn.frame = NSRect(x: 100, y: 485, width: 150, height: 28)
        resetBtn.bezelStyle = .rounded
        content.addSubview(resetBtn)

        let pLabel = note("Presets", NSRect(x: 20, y: 457, width: 150, height: 16))
        pLabel.maximumNumberOfLines = 1
        let presets = ["claude", "claude2", "claude3"]
        for (i, res) in presets.enumerated() {
            let b = NSButton(frame: NSRect(x: 20 + i * 46, y: 411, width: 40, height: 40))
            b.bezelStyle = .shadowlessSquare
            b.imageScaling = .scaleProportionallyUpOrDown
            b.imagePosition = .imageOnly
            if let p = Bundle.main.path(forResource: res, ofType: "gif"),
               let img = NSImage(contentsOfFile: p) {
                img.size = NSSize(width: 32, height: 32)
                b.image = img
            }
            b.tag = i; b.target = self; b.action = #selector(usePreset(_:))
            b.toolTip = "Use this icon"
            content.addSubview(b)
        }

        // --- Terminals per click ---
        _ = label("Terminals per click", NSRect(x: 20, y: 375, width: 250, height: 20), bold: true)

        let stepper = NSStepper(frame: NSRect(x: 20, y: 342, width: 24, height: 28))
        stepper.minValue = 1; stepper.maxValue = 8; stepper.increment = 1; stepper.valueWraps = false
        stepper.target = self; stepper.action = #selector(terminalsChanged(_:))
        content.addSubview(stepper)
        terminalsStepper = stepper

        let valueLabel = label("1", NSRect(x: 54, y: 344, width: 40, height: 20))
        valueLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        terminalsValueLabel = valueLabel

        let info = note("", NSRect(x: 20, y: 309, width: 360, height: 28))
        info.maximumNumberOfLines = 2
        terminalsInfoLabel = info

        let tile = NSButton(checkboxWithTitle: "Group 2+ terminals in a Claudey space",
                            target: self, action: #selector(tileToggled(_:)))
        tile.frame = NSRect(x: 20, y: 281, width: 360, height: 22)
        content.addSubview(tile)
        tileCheckbox = tile

        // --- Space appearance ---
        _ = label("Space appearance", NSRect(x: 20, y: 245, width: 250, height: 20), bold: true)

        _ = note("Transparency", NSRect(x: 20, y: 222, width: 120, height: 16)).maximumNumberOfLines = 1
        let slider = NSSlider(value: SPACE_OPACITY_DEFAULT, minValue: 0, maxValue: 1,
                              target: self, action: #selector(spaceOpacityChanged(_:)))
        slider.frame = NSRect(x: 130, y: 220, width: 190, height: 20)
        slider.isContinuous = true
        content.addSubview(slider)
        spaceOpacitySlider = slider

        let opLabel = label("59%", NSRect(x: 328, y: 220, width: 50, height: 18))
        opLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        spaceOpacityLabel = opLabel

        _ = note("Tint color", NSRect(x: 20, y: 188, width: 120, height: 16)).maximumNumberOfLines = 1
        let well = NSColorWell(frame: NSRect(x: 130, y: 180, width: 54, height: 26))
        well.target = self; well.action = #selector(spaceTintChanged(_:))
        content.addSubview(well)
        spaceTintWell = well

        _ = note("Background of the multi-terminal space. 0% = fully see-through.",
                 NSRect(x: 20, y: 150, width: 360, height: 24))

        // --- Caveman ---
        _ = label("Caveman", NSRect(x: 20, y: 110, width: 250, height: 20), bold: true)

        let cave = NSButton(checkboxWithTitle: "Auto-install Caveman on launch",
                            target: self, action: #selector(cavemanToggled(_:)))
        cave.frame = NSRect(x: 20, y: 82, width: 360, height: 22)
        content.addSubview(cave)
        cavemanCheckbox = cave

        _ = note("First launch installs the Caveman plugin if it’s missing, so anyone gets it without setup. Skipped once installed.",
                 NSRect(x: 20, y: 30, width: 360, height: 44))

        settingsWindow = win
    }

    // MARK: - Space appearance helpers

    func hexFromColor(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
    }

    func colorFromHex(_ hex: String) -> NSColor {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count != 6 { h = SPACE_TINT_DEFAULT }
        let scanner = Scanner(string: h)
        var v: UInt64 = 0
        scanner.scanHexInt64(&v)
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255,
                       green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    @objc func spaceOpacityChanged(_ sender: NSSlider) {
        let v = sender.doubleValue
        UserDefaults.standard.set(v, forKey: SPACE_OPACITY_KEY)
        spaceOpacityLabel?.stringValue = "\(Int((v * 100).rounded()))%"
    }

    @objc func spaceTintChanged(_ sender: NSColorWell) {
        UserDefaults.standard.set(hexFromColor(sender.color), forKey: SPACE_TINT_KEY)
    }

    func refreshSettingsUI() {
        logoPreview?.image = frames.first
        let n = max(1, UserDefaults.standard.integer(forKey: TERMINALS_KEY))
        terminalsStepper?.integerValue = n
        terminalsValueLabel?.stringValue = "\(n)"
        updateTerminalsInfo(n)
        cavemanCheckbox?.state = UserDefaults.standard.bool(forKey: CAVEMAN_KEY) ? .on : .off
        tileCheckbox?.state = UserDefaults.standard.bool(forKey: TILE_KEY) ? .on : .off

        let op = UserDefaults.standard.object(forKey: SPACE_OPACITY_KEY) as? Double ?? SPACE_OPACITY_DEFAULT
        spaceOpacitySlider?.doubleValue = op
        spaceOpacityLabel?.stringValue = "\(Int((op * 100).rounded()))%"
        let tint = UserDefaults.standard.string(forKey: SPACE_TINT_KEY) ?? SPACE_TINT_DEFAULT
        spaceTintWell?.color = colorFromHex(tint)
    }

    @objc func cavemanToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: CAVEMAN_KEY)
    }

    @objc func tileToggled(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: TILE_KEY)
    }

    func updateTerminalsInfo(_ n: Int) {
        if n == 1 {
            terminalsInfoLabel?.stringValue =
                "One click opens a single Terminal.app window running “claude”."
        } else {
            terminalsInfoLabel?.stringValue =
                "One click opens \(n) “claude” panes — in one Claudey space when grouped below, else \(n) Terminal windows."
        }
    }

    @objc func terminalsChanged(_ sender: NSStepper) {
        let n = sender.integerValue
        UserDefaults.standard.set(n, forKey: TERMINALS_KEY)
        terminalsValueLabel?.stringValue = "\(n)"
        updateTerminalsInfo(n)
    }

    @objc func chooseLogo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic, .bmp, .image]
        panel.prompt = "Use as Logo"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Copy into Application Support so the logo survives if the original moves.
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let dest = appSupportDir().appendingPathComponent("logo.\(ext)")
        // Remove any previous logo.* files.
        if let files = try? FileManager.default.contentsOfDirectory(at: appSupportDir(),
                                                                    includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("logo.") {
                try? FileManager.default.removeItem(at: f)
            }
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            UserDefaults.standard.set(dest.path, forKey: LOGO_KEY)
            reloadIcon()
            logoPreview?.image = frames.first
        } catch {
            NSLog("Logo copy failed: \(error)")
        }
    }

    @objc func resetLogo() {
        UserDefaults.standard.removeObject(forKey: LOGO_KEY)
        reloadIcon()
        logoPreview?.image = frames.first
    }

    @objc func usePreset(_ sender: NSButton) {
        let names = ["claude", "claude2", "claude3"]
        guard sender.tag >= 0, sender.tag < names.count else { return }
        if sender.tag == 0 {
            UserDefaults.standard.removeObject(forKey: LOGO_KEY) // bundled default
        } else if let p = Bundle.main.path(forResource: names[sender.tag], ofType: "gif") {
            UserDefaults.standard.set(p, forKey: LOGO_KEY)
        }
        reloadIcon()
        logoPreview?.image = frames.first
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
