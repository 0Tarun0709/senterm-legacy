import AppKit
import SwiftUI
import SwiftTerm
@testable import SenTerm

@main
struct SplitWindowProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = Store()
        let colors = GhosttyTheme(name: "test", text: "background = #102040\ncursor-color = #007acc\npalette = 2=#aabbcc\npalette = 256=#000000")!
        precondition(colors.colors["background"] == 0x102040 && colors.palette == [2: 0xaabbcc])
        precondition(GhosttyTheme(name: "bad", text: "foreground = #oo00oo") == nil)
        let contrast = WindowPalette(theme: .contrast)
        precondition(contrast.scheme == .dark && contrast.keepsOriginalMaterials)
        precondition(contrast.sidebar == SwiftUI.Color(rgb: 0x090c11))
        precondition(contrast.panel == SwiftUI.Color(rgb: 0x0d1015))
        for theme in [TerminalTheme.ocean, .paper, .original] {
            let palette = WindowPalette(theme: theme)
            precondition(!palette.keepsOriginalMaterials && palette.sidebar != contrast.sidebar)
            precondition(palette.panel != contrast.panel && palette.panel != palette.sidebar)
            precondition(palette.scheme == (theme == .paper ? .light : .dark))
        }
        precondition(!WindowPalette(theme: .contrast, imported: colors).keepsOriginalMaterials)
        let lightImport = GhosttyTheme(name: "light", text: "background = #ffffff")!
        precondition(WindowPalette(theme: .ocean, imported: lightImport).scheme == .light)
        precondition(TerminalShortcuts.parse("") == TerminalShortcuts.defaults)
        precondition(TerminalShortcuts.parse("find in terminal = shift+cmd+g") == nil)
        precondition(TerminalShortcuts.parse("find in terminal = none")?["find in terminal"] == "none")
        precondition(GPUPane.pasteNeedsConfirmation("one\ntwo", bracketed: false))
        precondition(!GPUPane.pasteNeedsConfirmation("one\ntwo", bracketed: true))
        precondition(GPUPane.pasteNeedsConfirmation("\u{1b}[201~", bracketed: true))
        precondition(!GPUPane.pasteNeedsConfirmation("one line", bracketed: false))
        let benchmark = ProcessInfo.processInfo.environment["SENTERM_EXTENDED_PROBE"] == "1"
        let project = Project(path: benchmark ? FileManager.default.currentDirectoryPath : NSTemporaryDirectory(),
                              terminals: [TerminalItem(name: "split check")])
        let tab = project.terminals[0]
        store.data = ProjectList(projects: [project])
        store.selected = tab.id
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let quitDelegate = AppDelegate()
        quitDelegate.onQuit = store.stopAllPanes
        var quitReply: NSApplication.TerminateReply?
        window.contentView = NSHostingView(rootView: ContentView(store: store)
            .background {
                ConfirmWindowClose { quitReply = quitDelegate.applicationShouldTerminate(app) }
                    .allowsHitTesting(false)
            })
        window.makeKeyAndOrderFront(nil)
        func update() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
        update()

        precondition(window.styleMask.contains(.fullSizeContentView))
        precondition(window.titleVisibility == .hidden && window.titlebarAppearsTransparent)
        precondition(window.standardWindowButton(.closeButton)?.isHidden == false)

        let first = store.terminal(tab.id, project: project)
        func clickAt(_ x: CGFloat, depth: CGFloat) {
            let point = CGPoint(x: x, y: window.frame.height - depth)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   eventNumber: 1, clickCount: 1, pressure: 1)!)
            }
            update()
        }
        let initialWidth = first.bounds.width
        clickAt(110, depth: 24.5)
        precondition(first.bounds.width > initialWidth + 200, "toolbar did not hide the sidebar")
        clickAt(104, depth: 26)
        precondition(abs(first.bounds.width - initialWidth) < 2, "toolbar did not restore the sidebar")
        clickAt(181, depth: 24.5)
        precondition(window.firstResponder is NSTextView, "toolbar did not open the command palette")
        clickAt(80, depth: 350) // dismiss the palette outside its panel
        precondition(window.firstResponder === first, "dismissing the palette did not restore terminal focus")
        let originalPID = first.process.shellPid
        precondition(originalPID > 0 && first.window === window)
        TerminalTheme.contrast.apply(to: first, imported: colors)
        precondition(first.nativeBackgroundColor == NSColor(srgbRed: 16.0 / 255, green: 32.0 / 255, blue: 64.0 / 255, alpha: 1))
        TerminalTheme.contrast.apply(to: first)
        precondition(!AgentProcesses.hasForegroundJob(shells: [originalPID]))
        first.insertText("cd /private/tmp\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        update()
        precondition(PaneSession.directory(pid: originalPID) == "/private/tmp")
        store.split(tab, projectID: project.id, vertical: false)
        update()
        let split = store.data.projects[0].terminals[0]
        let right = store.terminal(split.panes.ids[1], project: project)
        precondition(first.window === window && right.window === window)
        precondition(PaneSession.directory(pid: right.process.shellPid) == "/private/tmp")
        precondition(String(decoding: right.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self).isEmpty == false)
        precondition(first.bounds.width > 100 && abs(first.bounds.width - right.bounds.width) < 2)
        precondition(window.firstResponder === right)

        func dragDivider(after pane: NSView, vertical: Bool, by distance: CGFloat) {
            // The next terminal has leading/top padding beyond the one-point divider.
            let rect = pane.convert(pane.bounds, to: nil)
            let start = CGPoint(x: vertical ? rect.midX : rect.maxX + 0.5,
                                y: vertical ? rect.minY - 0.5 : rect.midY)
            let end = CGPoint(x: start.x + (vertical ? 0 : distance), y: start.y - (vertical ? distance : 0))
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1)!)
            }
            update()
        }
        let rightWidth = right.bounds.width
        dragDivider(after: first, vertical: false, by: 80)
        precondition(abs(right.bounds.width - rightWidth + 80) < 2, "drag did not shrink the right pane")
        dragDivider(after: first, vertical: false, by: -80)
        precondition(abs(right.bounds.width - rightWidth) < 2, "drag did not grow the right pane")

        func click(_ pane: NSView) {
            let point = pane.convert(CGPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                                   clickCount: 1, pressure: 1)!)
            }
            update()
        }
        click(first)
        precondition(window.firstResponder === first, "click did not focus the left pane")
        precondition(store.paneFocus == split.panes.ids[0], "left pane focus not reflected in the UI")
        click(right)
        precondition(window.firstResponder === right, "click did not focus the right pane")
        precondition(store.paneFocus == split.panes.ids[1], "right pane focus not reflected in the UI")
        let input = window.firstResponder as? NSTextInputClient
        precondition(input != nil)
        input?.insertText("printf '%s%s\\n' senterm-right -only\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        update()
        func containsOutput(_ pane: TerminalView, _ text: String) -> Bool {
            let terminal = pane.getTerminal()
            return (0..<terminal.rows).contains { terminal.getLine(row: $0)?.translateToString().contains(text) == true }
        }
        precondition(containsOutput(right, "senterm-right-only"), "typed command did not reach the right shell")
        precondition(!containsOutput(first, "senterm-right-only"), "typed command reached the left shell")
        let deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: GPUPane.handleDeleteShortcut)!
        defer { NSEvent.removeMonitor(deleteMonitor) }
        func pressDelete(_ modifiers: NSEvent.ModifierFlags) {
            app.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                              isARepeat: false, keyCode: 51)!)
        }
        right.send(txt: "printf '%s%s\\n' word- kept discarded")
        pressDelete(.option)
        right.send([13])
        update()
        precondition(containsOutput(right, "word-kept") && !containsOutput(right, "word-discarded"),
                     "option-delete did not remove the previous word")
        right.send(txt: "not-a-command ")
        pressDelete(.command)
        right.send(txt: "printf '%s%s\\n' line -cleared\r")
        update()
        precondition(containsOutput(right, "line-cleared"), "command-delete did not clear the input line")

        if ["/opt/homebrew/bin/delta", "/usr/local/bin/delta"].contains(where: FileManager.default.isExecutableFile(atPath:)) {
            right.insertText("/usr/bin/git config --get pager.diff\r", replacementRange: NSRange(location: NSNotFound, length: 0))
            update()
            precondition(containsOutput(right, "/delta --side-by-side"), "the pane did not set git's diff pager")
        }

        store.split(split, projectID: project.id, vertical: true)
        update()
        let nested = store.data.projects[0].terminals[0]
        let bottom = store.terminal(nested.panes.ids[2], project: project)
        precondition(bottom.window === window && window.firstResponder === bottom)
        precondition(right.bounds.height > 100 && abs(right.bounds.height - bottom.bounds.height) < 2)
        let bottomHeight = bottom.bounds.height
        dragDivider(after: right, vertical: true, by: 50)
        precondition(abs(bottom.bounds.height - bottomHeight + 50) < 2, "drag did not shrink the bottom pane")
        dragDivider(after: right, vertical: true, by: -50)
        precondition(abs(bottom.bounds.height - bottomHeight) < 2, "drag did not grow the bottom pane")
        let pids = [first, right, bottom].map { $0.process.shellPid }
        precondition(Set(pids).count == 3)
        precondition(pids.allSatisfy { getsid($0) == $0 }, "each shell must lead its own session")
        store.movePaneFocus(.up, in: nested)
        precondition(window.firstResponder === right)
        store.movePaneFocus(.left, in: nested)
        precondition(window.firstResponder === first)
        store.movePaneFocus(.left, in: nested)
        precondition(window.firstResponder === first)
        store.showPane(nested.panes.ids[2], in: nested)
        let originalWidth = bottom.bounds.width
        let originalHeight = bottom.bounds.height
        store.resizePane(.up, in: nested)
        update()
        precondition(abs(bottom.bounds.height - originalHeight - 10) < 2)
        precondition(abs(bottom.bounds.width - originalWidth) < 2)
        store.togglePaneZoom(in: nested)
        update()
        precondition(window.firstResponder === bottom && bottom.bounds.width > originalWidth * 1.8)
        let zoomWidth = bottom.bounds.width
        store.showPane(nested.panes.ids[0], in: nested)
        update()
        precondition(store.zoomedPanes[nested.id] == nested.panes.ids[0])
        precondition(window.firstResponder === first && abs(first.bounds.width - zoomWidth) < 2)
        store.showPane(nested.panes.ids[2], in: nested)
        update()
        precondition(window.firstResponder === bottom && abs(bottom.bounds.width - zoomWidth) < 2)
        precondition([first, right, bottom].map { $0.process.shellPid } == pids)
        store.togglePaneZoom(in: nested)
        update()
        precondition(abs(bottom.bounds.height - originalHeight - 10) < 2)
        store.equalizePanes()
        update()
        precondition(abs(bottom.bounds.height - originalHeight) < 2)
        precondition(first.process.shellPid == originalPID && [first, right, bottom].allSatisfy { $0.process.running })
        store.cyclePane(1, in: nested)
        precondition(window.firstResponder === first)
        store.cyclePane(-1, in: nested)
        precondition(window.firstResponder === bottom)

        bottom.feed(text: "\u{1b}]7;file:///tmp/example%20directory\u{7}")
        bottom.feed(text: "\r\n\u{1b}]133;P;k=i\u{7}first prompt\r\n" +
            String(repeating: "some output\r\n", count: 40) +
            "\u{1b}]133;P;k=i\u{7}second prompt\r\n" +
            String(repeating: "some output\r\n", count: 40))
        update()
        precondition(store.reportedDirectory(in: nested) == "/tmp/example directory")
        let end = bottom.getTerminal().getTopVisibleRow()
        store.jumpToPrompt(forward: false, in: nested)
        let secondPrompt = bottom.getTerminal().getTopVisibleRow()
        store.jumpToPrompt(forward: false, in: nested)
        precondition(bottom.getTerminal().getTopVisibleRow() < secondPrompt && secondPrompt < end)
        store.jumpToPrompt(forward: true, in: nested)
        precondition(bottom.getTerminal().getTopVisibleRow() == secondPrompt)

        store.find(.showFindInterface, in: nested)
        func searchField(in view: NSView) -> NSSearchField? {
            (view as? NSSearchField) ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
        }
        guard let field = searchField(in: bottom) else { fatalError("no search field") }
        precondition(!field.isHiddenOrHasHiddenAncestor)
        store.find(.hideFindInterface, in: nested)
        precondition(field.isHiddenOrHasHiddenAncestor)
        let other = TerminalItem(name: "other tab")
        store.data.projects[0].terminals.append(other)
        store.showPane(other.panes.firstID, in: other)
        update()
        let otherPane = store.terminal(other.panes.firstID, project: project)
        let otherPID = otherPane.process.shellPid
        store.showPane(nested.panes.ids[1], in: nested)
        update()
        func waitFor(_ description: String, _ condition: () -> Bool) {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            precondition(condition(), "timed out under log load: \(description)")
        }
        func keySamples(_ label: String) -> [Double] {
            right.send(txt: "/bin/bash -c 'printf \"\\nkey-%s-ready\\n\" \(label); for (( i=0;i<16;i++ )); do IFS= read -rsn1 key || exit; printf \"\\nkey-%s-%d-%s\\n\" \(label) \"$i\" \"$key\"; done'\r")
            waitFor("echo child ready") { containsOutput(right, "key-\(label)-ready") }
            return (0..<16).map { index in
                let expected = "key-\(label)-\(index)-a"
                let time = milliseconds {
                    right.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!)
                    waitFor("key echo \(index)") { containsOutput(right, expected) }
                }
                return time
            }
        }
        func report(_ label: String, _ times: [Double]) {
            let sorted = times.sorted()
            print(String(format: "%@: median %.2f ms, p95 %.2f ms (%d samples)", label,
                (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2,
                sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1], sorted.count))
        }
        report("local key to terminal model, idle", keySamples("idle"))
        bottom.scroll(toPosition: 1)
        bottom.insertText("/bin/bash -c 'for (( i=0;i<100;i++ )); do printf \"load row %s\\n\" {1..256}; /bin/sleep .02; done; printf \"%s%s\\n\" load -done'\r",
                          replacementRange: NSRange(location: NSNotFound, length: 0))
        waitFor("first log batch") { containsOutput(bottom, "load row 255") }
        precondition(AgentProcesses.hasForegroundJob(shells: [bottom.process.shellPid]))
        func milliseconds(_ action: () -> Void) -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            action()
            return (ProcessInfo.processInfo.systemUptime - start) * 1000
        }
        report("local key to terminal model, background logs", keySamples("loaded"))
        let reply = milliseconds {
            right.insertText("printf '%s%s\\n' foreground -ok\r", replacementRange: NSRange(location: NSNotFound, length: 0))
            waitFor("foreground shell reply") { containsOutput(right, "foreground-ok") }
        }
        let switchTime = milliseconds {
            store.showPane(other.panes.firstID, in: other)
            waitFor("focus other tab") { window.firstResponder === otherPane }
        }
        store.selected = nested.id
        waitFor("restore the original tab’s focused pane") { window.firstResponder === right }
        waitFor("last log batch") { containsOutput(bottom, "load-done") }
        guard let scroller = bottom.subviews.compactMap({ $0 as? NSScroller }).first else {
            fatalError("missing terminal scroller")
        }
        precondition(scroller.isEnabled && abs(scroller.knobProportion - bottom.scrollThumbsize) < 0.001)
        report("scroll jump to viewport state", (0..<16).map { index in
            let position = Double(index % 2)
            return milliseconds {
                bottom.scroll(toPosition: position)
                precondition(scroller.doubleValue == position && bottom.scrollPosition == position)
            }
        })
        print(String(format: "log load: shell reply %.1f ms, tab focus %.1f ms", reply, switchTime))
        func exitShell(_ pane: LocalProcessTerminalView) {
            pane.insertText("exit\r", replacementRange: NSRange(location: NSNotFound, length: 0))
            update()
        }
        exitShell(first)
        precondition(store.data.projects[0].terminals.first?.panes.ids == Array(nested.panes.ids.dropFirst()), "exit removed more than the original pane")
        precondition(right.process.running && bottom.process.running && otherPane.process.running)
        precondition(window.firstResponder === right, "exiting a different pane stole focus")
        exitShell(bottom)
        precondition(store.data.projects[0].terminals.first?.panes.ids == [nested.panes.ids[1]])
        precondition(right.process.running && right.process.shellPid == pids[1])
        right.insertText("printf '%s%s\\n' survivor -still-running\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        update()
        precondition(containsOutput(right, "survivor-still-running"))
        exitShell(right)
        precondition(store.data.projects[0].terminals == [other] && store.selected == other.id)
        precondition(otherPane.process.running && otherPane.process.shellPid == otherPID)
        for exitIndex in [1, 0] {
            store.split(other, projectID: project.id, vertical: false)
            update()
            let pair = store.data.projects[0].terminals[0]
            let closing = store.terminal(pair.panes.ids[exitIndex], project: project)
            let survivorID = pair.panes.ids[1 - exitIndex]
            let survivor = store.terminal(survivorID, project: project)
            let survivorPID = survivor.process.shellPid
            click(closing)
            precondition(window.firstResponder === closing)
            exitShell(closing)
            waitFor("closed pane removed") { store.selected == other.id && store.data.projects[0].terminals[0].panes.ids == [survivorID] }
            precondition(survivor.process.running && survivor.process.shellPid == survivorPID)
            waitFor("surviving pane visible and focused") { survivor.window === window && window.firstResponder === survivor }
            (window.firstResponder as? NSTextInputClient)?.insertText("printf '%s%s\\n' pane-survived- \(exitIndex)\r",
                replacementRange: NSRange(location: NSNotFound, length: 0))
            waitFor("survivor receives input") { containsOutput(survivor, "pane-survived-\(exitIndex)") }
        }
        let last = store.terminal(store.data.projects[0].terminals[0].panes.firstID, project: project)
        if benchmark {
            func resources(_ label: String) {
                var taskInfo = mach_task_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
                let status = withUnsafeMutablePointer(to: &taskInfo) { pointer in
                    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                    }
                }
                precondition(status == KERN_SUCCESS)
                let cpu = clock()
                RunLoop.main.run(until: Date().addingTimeInterval(2))
                print(String(format: "%@: %.1f mib rss, %.2f%% app cpu over 2 s", label,
                    Double(taskInfo.resident_size) / 1_048_576, Double(clock() - cpu) * 50 / Double(CLOCKS_PER_SEC)))
            }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            func smoke(_ label: String, _ command: String, _ marker: String, _ quit: String, _ file: String? = nil) {
                last.send(txt: "\(command); printf '\\n%s%s-%d\\n' returned- \(label) $?\r")
                waitFor("\(label) screen") { containsOutput(last, marker) }
                last.send(txt: quit)
                waitFor("\(label) returned to shell") { containsOutput(last, "returned-\(label)-0") }
                if let file {
                    let text = try! String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
                    precondition(text == "vim-probe\n")
                }
                print("\(label) smoke passed")
            }
            smoke("vim", "/usr/bin/vim -Nu NONE -i NONE -n -c 'call setline(1, \"vim\" . \"-probe\")' check.txt", "vim-probe", ":wq\r", "check.txt")
            func shellPath(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            if let tmux = ProcessInfo.processInfo.environment["SENTERM_TEST_TMUX"] {
                let socket = shellPath(directory.appendingPathComponent("tmux.sock").path)
                smoke("tmux", "\(shellPath(tmux)) -S \(socket) -f /dev/null new-session -s probe 'printf tmux-%s ready; read line'", "tmux-ready", "\r")
            } else { print("tmux: skipped (not installed)") }
            if let vttest = ProcessInfo.processInfo.environment["SENTERM_TEST_VTTEST"] {
                smoke("vttest", shellPath(vttest), "Test of cursor", "0\r")
            } else { print("vttest: skipped (not installed)") }
            resources("one project, one live shell")
            var started = [last]
            for index in 1...5 {
                let path = directory.appendingPathComponent("project-\(index)")
                try! FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
                let item = TerminalItem(name: "terminal")
                let project = Project(path: path.path, terminals: [item])
                store.data.projects.append(project)
                store.showPane(item.id, in: item)
                let pane = store.terminal(item.panes.firstID, project: project)
                waitFor("project \(index) running and focused") { pane.process.running && window.firstResponder === pane }
                started.append(pane)
            }
            precondition(started.allSatisfy { $0.process.running })
            resources("six projects, six live shells")
            store.showPane(other.panes.firstID, in: other)
            waitFor("original project") { window.firstResponder === last }
        }
        for (response, expected) in [(NSApplication.ModalResponse.alertSecondButtonReturn, NSApplication.TerminateReply.terminateCancel),
                                     (.alertFirstButtonReturn, .terminateNow)] {
            let replyToAlert = Timer(timeInterval: 0.02, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard app.modalWindow != nil else { return }
                    precondition(window.isVisible && last.process.running, "close changed the window or shell before confirmation")
                    timer.invalidate()
                    app.stopModal(withCode: response)
                }
            }
            RunLoop.main.add(replyToAlert, forMode: .modalPanel)
            window.performClose(nil)
            update()
            replyToAlert.invalidate()
            precondition(quitReply == expected, "close did not use quit confirmation")
            if expected == .terminateCancel {
                precondition(window.isVisible && last.process.running, "cancel did not preserve the window and shell")
            }
        }
        precondition(!last.process.running, "confirmed quit did not stop the shell")
        print("split window probe passed")
    }
}
