import AppKit
import Carbon.HIToolbox
import MetalKit
import SwiftTerm

final class GPUPane: LocalProcessTerminalView {
    private var triedMetal = false
    private var receivingOutput = false
    private var pendingScrollRow: Int?
    var onFocus: (() -> Void)?
    var lastCompletionNotice = Date.distantPast

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // The Metal canvas draws the grid; the terminal itself handles its input.
        return hit is MTKView ? self : hit
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        receivingOutput = true
        super.dataReceived(slice: slice)
        receivingOutput = false
        if let row = pendingScrollRow {
            pendingScrollRow = nil
            super.scrolled(source: getTerminal(), yDisp: row)
        }
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        // SwiftTerm reports every newline that scrolls; AppKit only needs the final position.
        if receivingOutput {
            pendingScrollRow = yDisp
        } else {
            super.scrolled(source: terminal, yDisp: yDisp)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder === self || window.makeFirstResponder(self) { onFocus?() }
        super.mouseDown(with: event)
    }

    static func handleDeleteShortcut(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == UInt16(kVK_Delete),
              let pane = event.window?.firstResponder as? GPUPane,
              pane.getTerminal().keyboardEnhancementFlags.isEmpty else { return event }
        switch event.modifierFlags.intersection([.command, .option, .control, .shift]) {
        case .command: pane.send([0x15]) // ctrl-u
        case .option: pane.send([0x1b, 0x7f]) // meta-backspace
        default: return event
        }
        return nil
    }

    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        let steady: CursorStyle = switch newStyle {
        case .blinkBlock: .steadyBlock
        case .blinkUnderline: .steadyUnderline
        case .blinkBar: .steadyBar
        default: newStyle
        }
        // Metal reads the style from the terminal options, not the caret view.
        source.options.cursorStyle = steady
        super.cursorStyleChanged(source: source, newStyle: steady)
    }

    static func pasteNeedsConfirmation(_ text: String, bracketed: Bool) -> Bool {
        // An escape in the clipboard can terminate bracketed paste early.
        return text.unicodeScalars.contains {
            $0.value == 27 || (0x80...0x9f).contains($0.value) || (!bracketed && $0.value < 32 && $0.value != 9)
        }
    }

    override func paste(_ sender: Any) {
        let clipboard = NSPasteboard.general
        let change = clipboard.changeCount
        if let text = clipboard.string(forType: .string),
           Self.pasteNeedsConfirmation(text, bracketed: getTerminal().bracketedPasteMode) {
            let alert = NSAlert()
            alert.messageText = "paste into terminal?"
            alert.informativeText = "this text contains line breaks or control characters that can run commands."
            alert.addButton(withTitle: "cancel")
            let paste = alert.addButton(withTitle: "paste")
            paste.keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn,
                  clipboard.changeCount == change, process.running, window?.firstResponder === self else { return }
        }
        super.paste(sender)
    }

    func find(_ action: NSTextFinder.Action) {
        let item = NSMenuItem()
        item.tag = action.rawValue
        performTextFinderAction(item)
    }

    func jumpToPrompt(forward: Bool) {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate else { return }
        let top = terminal.getTopVisibleRow()
        var row = top + (forward ? 1 : -1)
        while terminal.bufferLine(atRow: row) != nil {
            if terminal.semanticPromptMarks(at: row).contains(where: { $0.kind == .initial }) {
                scrollTo(row: row)
                return
            }
            row += forward ? 1 : -1
        }
        if forward { scroll(toPosition: 1) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !triedMetal else { return }
        triedMetal = true
        guard !UserDefaults.standard.bool(forKey: "disableMetal") else { return }
        do {
            try setUseMetal(true)
        } catch {
            NSLog("senterm: metal unavailable, using core graphics: %@", String(describing: error))
        }
    }
}
