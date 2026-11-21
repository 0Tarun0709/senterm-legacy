import AppKit
import Carbon.HIToolbox
import GhosttyVt
import SwiftTerm

// shortcut: a separate window and CPU renderer for validating VT integration, not the project-pane replacement.
final class GhosttyPreview: NSView, LocalProcessDelegate, NSWindowDelegate {
    private var terminal: GhosttyTerminal?
    private var render: GhosttyRenderState?
    private var rows: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var encoder: GhosttyKeyEncoder?
    private var key: GhosttyKeyEvent?
    private(set) lazy var process = LocalProcess(delegate: self)
    private let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private let padding: CGFloat = 8
    private lazy var cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
    private lazy var cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
    private var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    private var wheel: CGFloat = 0

    init?(previewFrame: NSRect) {
        super.init(frame: previewFrame)
        guard ghostty_terminal_new(nil, &terminal, 80, 24) == GHOSTTY_SUCCESS,
              ghostty_render_state_new(nil, &render) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_iterator_new(nil, &rows) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_key_event_new(nil, &key) == GHOSTTY_SUCCESS,
              ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque()) == GHOSTTY_SUCCESS else { return nil }
        let reply: GhosttyTerminalWritePtyFn = { _, context, bytes, count in
            guard let context, let bytes, count > 0 else { return }
            let view = Unmanaged<GhosttyPreview>.fromOpaque(context).takeUnretainedValue()
            view.process.send(data: Array(UnsafeBufferPointer(start: bytes, count: count))[...])
        }
        guard ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                                   unsafeBitCast(reply, to: UnsafeRawPointer.self)) == GHOSTTY_SUCCESS else { return nil }
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("experimental libghostty terminal")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let key { ghostty_key_event_free(key) }
        if let encoder { ghostty_key_encoder_free(encoder) }
        if let cells { ghostty_render_state_row_cells_free(cells) }
        if let rows { ghostty_render_state_row_iterator_free(rows) }
        if let render { ghostty_render_state_free(render) }
        if let terminal { ghostty_terminal_free(terminal) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    func start(directory: String, shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") {
        resizeTerminal()
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "senterm-ghostty-preview"
        process.startProcess(executable: shell, args: ["-l"], environment: environment.map { "\($0.key)=\($0.value)" }, currentDirectory: directory)
    }

    func stop() {
        guard process.running else { return }
        PaneSession.stopJobs(shell: process.shellPid)
        process.terminate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard process.running else { return true }
        let alert = NSAlert()
        alert.messageText = "close the preview terminal?"
        alert.informativeText = "its shell and running commands will stop."
        alert.addButton(withTitle: "close terminal")
        alert.addButton(withTitle: "cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) { stop() }
    func windowDidBecomeKey(_ notification: Notification) { needsDisplay = true }
    func windowDidResignKey(_ notification: Notification) { needsDisplay = true }

    func getWindowSize() -> winsize { size }
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        window?.title = "libghostty preview — shell exited"
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeTerminal()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeTerminal()
    }

    private func resizeTerminal() {
        guard let terminal else { return }
        let cols = UInt16(clamping: max(1, Int((bounds.width - padding * 2) / cellWidth)))
        let rows = UInt16(clamping: max(1, Int((bounds.height - padding * 2) / cellHeight)))
        let scale = window?.backingScaleFactor ?? 1
        let w = UInt32((cellWidth * scale).rounded())
        let h = UInt32((cellHeight * scale).rounded())
        guard ghostty_terminal_resize(terminal, cols, rows, w, h) == GHOSTTY_SUCCESS else { return }
        size = winsize(ws_row: rows, ws_col: cols, ws_xpixel: UInt16(clamping: UInt32(cols) * w),
                       ws_ypixel: UInt16(clamping: UInt32(rows) * h))
        if process.childfd >= 0 { _ = ioctl(process.childfd, TIOCSWINSZ, &size) }
        needsDisplay = true
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        slice.withUnsafeBufferPointer { ghostty_terminal_vt_write(terminal, $0.baseAddress, $0.count) }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        wheel -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY
        let delta = Int(wheel)
        guard delta != 0 else { return }
        wheel -= CGFloat(delta)
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
        scroll.value.delta = delta
        _ = ghostty_terminal_scroll_viewport(terminal, scroll)
        needsDisplay = true
    }

    private func send(_ bytes: [UInt8]) {
        guard process.running, !bytes.isEmpty else { return }
        var scroll = GhosttyTerminalScrollViewport()
        scroll.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM
        _ = ghostty_terminal_scroll_viewport(terminal, scroll)
        needsDisplay = true
        process.send(data: bytes[...])
    }

    private static let specialKeys: [Int: GhosttyKey] = [
        kVK_LeftArrow: GHOSTTY_KEY_ARROW_LEFT, kVK_RightArrow: GHOSTTY_KEY_ARROW_RIGHT,
        kVK_UpArrow: GHOSTTY_KEY_ARROW_UP, kVK_DownArrow: GHOSTTY_KEY_ARROW_DOWN,
        kVK_Home: GHOSTTY_KEY_HOME, kVK_End: GHOSTTY_KEY_END,
        kVK_PageUp: GHOSTTY_KEY_PAGE_UP, kVK_PageDown: GHOSTTY_KEY_PAGE_DOWN,
        kVK_ForwardDelete: GHOSTTY_KEY_DELETE, kVK_Delete: GHOSTTY_KEY_BACKSPACE,
        kVK_Return: GHOSTTY_KEY_ENTER, kVK_ANSI_KeypadEnter: GHOSTTY_KEY_ENTER,
        kVK_Tab: GHOSTTY_KEY_TAB, kVK_Escape: GHOSTTY_KEY_ESCAPE,
    ]

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        if event.keyCode == kVK_Delete {
            if flags == .command { send([0x15]); return }
            if flags == .option { send([0x1b, 0x7f]); return }
        }
        guard !flags.contains(.command) else { super.keyDown(with: event); return }
        guard let special = Self.specialKeys[Int(event.keyCode)] else {
            if let text = event.characters { send(Array(text.utf8)) }
            return
        }
        var mods: GhosttyMods = 0
        if flags.contains(.shift) { mods |= 1 }
        if flags.contains(.control) { mods |= 2 }
        if flags.contains(.option) { mods |= 4 }
        _ = ghostty_key_encoder_set_from_terminal(encoder, terminal)
        _ = ghostty_key_event_set_action(key, event.isARepeat ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_PRESS)
        _ = ghostty_key_event_set_key(key, special)
        _ = ghostty_key_event_set_mods(key, mods)
        var bytes = [UInt8](repeating: 0, count: 128)
        var count = 0
        if ghostty_key_encoder_encode(encoder, key, &bytes, bytes.count, &count) == GHOSTTY_SUCCESS {
            send(Array(bytes.prefix(count)))
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
            if event.keyCode == kVK_Delete { keyDown(with: event); return true }
            if event.charactersIgnoringModifiers == "v" { paste(nil); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        let clipboard = NSPasteboard.general
        let change = clipboard.changeCount
        guard let text = clipboard.string(forType: .string), process.running else { return }
        // Check conservatively even if the shell is in bracketed paste mode.
        if GPUPane.pasteNeedsConfirmation(text, bracketed: false) {
            let alert = NSAlert()
            alert.messageText = "paste into terminal?"
            alert.informativeText = "line breaks or control characters can run commands."
            alert.addButton(withTitle: "cancel")
            alert.addButton(withTitle: "paste").keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn,
                  clipboard.changeCount == change, window?.firstResponder === self else { return }
        }
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode)
        send(Array((mode.value ? "\u{1b}[200~\(text)\u{1b}[201~" : text).utf8))
    }

    private func color(_ rgb: GhosttyColorRgb) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard ghostty_render_state_update(render, terminal) == GHOSTTY_SUCCESS else { return }
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        guard ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) == GHOSTTY_SUCCESS,
              ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows) == GHOSTTY_SUCCESS else { return }
        color(colors.background).setFill()
        dirtyRect.fill()
        let foreground = color(colors.foreground)
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        _ = ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        let focused = window?.isKeyWindow == true && window?.firstResponder === self
        var text = ""
        var row = 0
        var bytes = [UInt8](repeating: 0, count: 64)
        while ghostty_render_state_row_iterator_next(rows) {
            guard ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS else { break }
            let y = padding + CGFloat(row) * cellHeight
            var col = 0
            while ghostty_render_state_row_cells_next(cells) {
                let rect = NSRect(x: padding + CGFloat(col) * cellWidth, y: y, width: cellWidth, height: cellHeight)
                let caret = cursor.visible && cursor.viewport_has_value && row == Int(cursor.viewport_y) && col == Int(cursor.viewport_x)
                var rgb = GhosttyColorRgb()
                let background = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &rgb) == GHOSTTY_SUCCESS
                    ? color(rgb) : nil
                if let fill = caret && focused ? foreground : background { fill.setFill(); rect.fill() }
                if caret && !focused { foreground.setStroke(); rect.insetBy(dx: 0.5, dy: 0.5).frame(withWidth: 1) }
                let ink = caret && focused ? color(colors.background) :
                    (ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &rgb) == GHOSTTY_SUCCESS ? color(rgb) : foreground)
                let glyph = bytes.withUnsafeMutableBufferPointer { buffer -> String in
                    var output = GhosttyBuffer(ptr: buffer.baseAddress, cap: buffer.count, len: 0)
                    let result = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &output)
                    if result == GHOSTTY_OUT_OF_SPACE { return "\u{fffd}" }
                    guard result == GHOSTTY_SUCCESS, output.len > 0 else { return " " }
                    return String(decoding: buffer.prefix(output.len), as: UTF8.self)
                }
                if glyph != " " {
                    (glyph as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1), withAttributes: [.font: font, .foregroundColor: ink])
                }
                text += glyph
                col += 1
            }
            text += "\n"
            row += 1
        }
        setAccessibilityValue(text)
    }
}
