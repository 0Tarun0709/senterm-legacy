import AppKit
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class Store: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var data: ProjectList {
        didSet {
            if let encoded = try? JSONEncoder().encode(data) {
                UserDefaults.standard.set(encoded, forKey: "projects")
            }
        }
    }
    @Published var selected: UUID?
    @Published var gitChanges: GitChangesRequest?
    @Published var fontSize: Double = UserDefaults.standard.object(forKey: "fontSize") as? Double ?? 13 {
        didSet {
            UserDefaults.standard.set(fontSize, forKey: "fontSize")
            for view in views.values { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        }
    }
    @Published var theme = UserDefaults.standard.string(forKey: "terminalTheme")
        .flatMap(TerminalTheme.init(rawValue:)) ?? .contrast {
        didSet {
            UserDefaults.standard.set(theme.rawValue, forKey: "terminalTheme")
            refreshTheme()
        }
    }
    var windowPalette: WindowPalette { WindowPalette(theme: theme, imported: importedTheme) }

    @Published var importedTheme = UserDefaults.standard.data(forKey: "importedTerminalTheme")
        .flatMap { try? JSONDecoder().decode(GhosttyTheme.self, from: $0) } {
        didSet {
            UserDefaults.standard.set(importedTheme.flatMap { try? JSONEncoder().encode($0) }, forKey: "importedTerminalTheme")
            refreshTheme()
        }
    }

    private func refreshTheme() {
        for view in views.values { theme.apply(to: view, imported: importedTheme) }
    }

    @Published var shortcutText = UserDefaults.standard.string(forKey: "terminalShortcuts") ?? "" {
        didSet {
            shortcuts = TerminalShortcuts.parse(shortcutText) ?? TerminalShortcuts.defaults
            UserDefaults.standard.set(shortcutText, forKey: "terminalShortcuts")
        }
    }
    private lazy var shortcuts = TerminalShortcuts.parse(shortcutText) ?? TerminalShortcuts.defaults

    func shortcut(_ name: String) -> KeyboardShortcut? {
        shortcuts[name].flatMap(TerminalShortcuts.binding)
    }

    private var views: [UUID: GPUPane] = [:]
    @Published private var paneDirectories: [UUID: String] = [:]
    private var splitDirectories: [UUID: String] = [:]
    @Published var scrollbackLines = min(100_000, max(500, UserDefaults.standard.object(forKey: "scrollbackLines") as? Int ?? 10_000)) {
        didSet {
            UserDefaults.standard.set(scrollbackLines, forKey: "scrollbackLines")
            for view in views.values { view.changeScrollback(scrollbackLines) }
        }
    }

    func exportScrollback(in item: TerminalItem) {
        guard let view = views[focusPane(in: item)] else { return }
        let contents = view.getTerminal().getBufferAsData(kind: .normal)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "terminal-transcript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    @Published private(set) var activity: [UUID: ActivityRecords] = [:]
    @Published private var paneFocusByTab: [UUID: UUID] = [:]
    private(set) var paneFocus: UUID? {
        get { selected.flatMap { paneFocusByTab[$0] } }
        set { if let selected { paneFocusByTab[selected] = newValue } }
    }
    @Published private(set) var zoomedPanes: [UUID: UUID] = [:]
    @Published private(set) var paneAdjustment: PaneAdjustment?
    @Published private var processes: [UUID: String] = [:]
    @Published private(set) var runningJobs: [UUID: [AgentProcesses.Job]] = [:]

    func processName(in item: TerminalItem) -> String? {
        let active = item.panes.ids.lazy.compactMap { self.processes[$0] }
        return active.first(where: AgentProcesses.isAgent) ?? active.first
    }

    func watchProcesses(includeJobs: Bool) async {
        if !includeJobs, !runningJobs.isEmpty { runningJobs = [:] }
        var poll = 0
        while !Task.isCancelled {
            let checkIdle = poll % 5 != 0
            poll += 1
            let shells = views.compactMapValues { view in
                view.process.running && view.process.shellPid > 0 ? view.process.shellPid : nil
            }
            if !shells.isEmpty {
                let pids = Set(shells.values)
                let result = await Task.detached(priority: .utility) {
                    AgentProcesses.snapshot(shells: pids, includeJobs: includeJobs, checkIdle: checkIdle)
                }.value
                guard !Task.isCancelled else { return }
                let live = shells.filter { views[$0.key]?.process.shellPid == $0.value }
                let badges = live.compactMapValues { result.badges[$0] }
                let jobs = live.compactMapValues { result.jobs[$0] }
                if processes != badges { processes = badges }
                if runningJobs != jobs { runningJobs = jobs }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    override init() {
        let saved = UserDefaults.standard.data(forKey: "projects")
        data = saved.flatMap { try? JSONDecoder().decode(ProjectList.self, from: $0) } ?? ProjectList()
        super.init()
        selected = data.firstTerminalID
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source, let id = self.views.first(where: { $0.value === source })?.key else { return }
            let path = directory.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
            if self.paneDirectories[id] != path { self.paneDirectories[id] = path }
        }
    }

    func reportedDirectory(in item: TerminalItem) -> String? {
        paneDirectories[focusPane(in: item)]
    }

    func find(_ action: NSTextFinder.Action, in item: TerminalItem) {
        views[focusPane(in: item)]?.find(action)
    }

    func jumpToPrompt(forward: Bool, in item: TerminalItem) {
        views[focusPane(in: item)]?.jumpToPrompt(forward: forward)
    }
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self, weak source] in
            guard let self, let source,
                  let id = self.views.first(where: { $0.value === source })?.key,
                  let project = self.data.projects.first(where: { $0.terminals.contains { $0.panes.ids.contains(id) } }),
                  let item = project.terminals.first(where: { $0.panes.ids.contains(id) }) else { return }
            self.closePane(id, item: item, projectID: project.id, shellExited: true)
        }
    }

    func status(_ id: UUID) -> String {
        let item = data.projects.lazy.flatMap(\.terminals).first { $0.id == id }
        return item?.panes.ids.contains { views[$0]?.process.running == true } == true ? "running" : "not started"
    }

    func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func selectRelative(_ offset: Int) {
        let ids = data.projects.flatMap { $0.terminals.map(\.id) }
        guard !ids.isEmpty else { return }
        guard let selected, let index = ids.firstIndex(of: selected) else { self.selected = ids.first; return }
        self.selected = ids[(index + offset + ids.count) % ids.count]
    }

    func terminal(_ id: UUID, project: Project) -> LocalProcessTerminalView {
        if let view = views[id] { return view }
        let view = GPUPane(frame: .zero, options: TerminalOptions(cursorStyle: .steadyBlock, scrollback: scrollbackLines))
        view.bellStyle = .none
        view.processDelegate = self
        view.onFocus = { [weak self, weak view] in
            DispatchQueue.main.async {
                guard let self, let view, self.views[id] === view, view.window?.firstResponder === view,
                      self.data.projects.lazy.flatMap(\.terminals).first(where: { $0.id == self.selected })?.panes.ids.contains(id) == true,
                      self.paneFocus != id else { return }
                self.paneFocus = id
            }
        }
        view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        theme.apply(to: view, imported: importedTheme)
        views[id] = view
        // shortcut: reports clear on pane closure, add prompt/reset hooks when SwiftTerm exposes them.
        view.getTerminal().registerOscHandler(code: 7501) { [weak self, weak view] bytes in
            guard bytes.count <= 4087 else { return }
            let payload = String(decoding: bytes, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, let view, self.views[id] === view else { return }
                if payload == "?" {
                    view.getTerminal().sendResponse(text: "\u{1b}]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\u{1b}\\")
                } else {
                    var records = self.activity[id] ?? ActivityRecords()
                    if records.apply(payload) { self.activity[id] = records }
                }
            }
        }
        view.getTerminal().registerOscHandler(code: 7502) { [weak self, weak view] bytes in
            guard bytes.count <= 20 else { return }
            let fields = String(decoding: bytes, as: UTF8.self).split(separator: ";")
            guard fields.count == 2, fields[0] == "senterm-done", let status = UInt8(fields[1]) else { return }
            DispatchQueue.main.async {
                guard let self, let view, self.views[id] === view,
                      UserDefaults.standard.bool(forKey: "commandNotifications"),
                      Bundle.main.bundleIdentifier != nil,
                      !(view.window?.isKeyWindow == true && view.window?.firstResponder === view),
                      Date().timeIntervalSince(view.lastCompletionNotice) >= 10 else { return }
                view.lastCompletionNotice = Date()
                let content = UNMutableNotificationContent()
                content.title = status == 0 ? "terminal command finished" : "terminal command exited with status \(status)"
                content.body = project.name
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                    if let error { NSLog("senterm: notification not delivered: %@", error.localizedDescription) }
                }
            }
        }
        let diffToken = UUID().uuidString
        view.getTerminal().registerOscHandler(code: 7503) { [weak self, weak view] bytes in
            guard bytes.count <= 48 else { return }
            let fields = String(decoding: bytes, as: UTF8.self).split(separator: ";")
            guard fields.count == 2, fields[0] == diffToken,
                  let scope = GitChanges.Scope(rawValue: String(fields[1])) else { return }
            DispatchQueue.main.async {
                guard let self, let view, self.views[id] === view,
                      view.window?.isKeyWindow == true, view.window?.firstResponder === view,
                      let path = PaneSession.directory(pid: view.process.shellPid) else { return }
                self.gitChanges = GitChangesRequest(path: path, scope: scope)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        let inherited = ProcessInfo.processInfo.environment
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        var environment = Terminal.getEnvironmentVariables() + ["TERM_PROGRAM=senterm"]
        // shortcut: check standard homebrew paths; add a configurable path if other installs need support.
        if let delta = ["/opt/homebrew/bin/delta", "/usr/local/bin/delta"].first(where: FileManager.default.isExecutableFile(atPath:)) {
            environment += ["GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=pager.diff",
                            "GIT_CONFIG_VALUE_0=\(delta) --side-by-side"]
        }
        if URL(fileURLWithPath: shell).lastPathComponent == "zsh",
           !UserDefaults.standard.bool(forKey: "disableZshIntegration"),
           let directory = Bundle.main.resourceURL?.appendingPathComponent("zsh"),
           FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(".zshenv").path) {
            if let original = inherited["ZDOTDIR"] { environment.append("SENTERM_ORIGINAL_ZDOTDIR=\(original)") }
            environment += ["ZDOTDIR=\(directory.path)", "SENTERM_DIFF_TOKEN=\(diffToken)"]
        } else if let original = inherited["ZDOTDIR"] {
            environment.append("ZDOTDIR=\(original)")
        }
        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: environment,
            currentDirectory: splitDirectories.removeValue(forKey: id).flatMap { directoryExists($0) ? $0 : nil } ?? project.path
        )
        return view
    }

    func openProject(_ url: URL) {
        let id = data.addProject(path: url.path)
        selected = data.projects.first(where: { $0.id == id })?.terminals.first?.id
    }

    func addTerminal(projectID: UUID) {
        guard let index = data.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let item = TerminalItem(name: "terminal")
        data.projects[index].terminals.append(item)
        selected = item.id
    }

    func rename(_ item: TerminalItem, projectID: UUID) {
        guard let name = askName("rename terminal", initial: item.name),
              let p = data.projects.firstIndex(where: { $0.id == projectID }),
              let t = data.projects[p].terminals.firstIndex(where: { $0.id == item.id }) else { return }
        data.projects[p].terminals[t].name = name
    }

    func renameProject(_ project: Project) {
        guard let name = askName("rename project", initial: project.name),
              let index = data.projects.firstIndex(where: { $0.id == project.id }) else { return }
        data.projects[index].label = name
    }

    func removeTerminal(_ item: TerminalItem, projectID: UUID) {
        guard confirm("close \(item.name)?", "its running shell and commands will be stopped.") else { return }
        guard let current = data.projects.first(where: { $0.id == projectID })?.terminals.first(where: { $0.id == item.id }) else { return }
        current.panes.ids.forEach { stopPane($0) }
        removeTab(item.id, projectID: projectID)
    }

    private func removeTab(_ id: UUID, projectID: UUID) {
        zoomedPanes.removeValue(forKey: id)
        paneFocusByTab.removeValue(forKey: id)
        let next = data.removeTerminal(id: id, projectID: projectID)
        if selected == id { selected = next ?? data.firstTerminalID }
    }

    func focusPane(in item: TerminalItem) -> UUID {
        item.panes.ids.first { id in
            guard let view = views[id] else { return false }
            return view.window?.firstResponder === view
        } ?? paneFocus.flatMap { item.panes.ids.contains($0) ? $0 : nil } ?? item.panes.firstID
    }

    func split(_ item: TerminalItem, projectID: UUID, vertical: Bool) {
        guard let p = data.projects.firstIndex(where: { $0.id == projectID }),
              let t = data.projects[p].terminals.firstIndex(where: { $0.id == item.id }) else { return }
        let current = data.projects[p].terminals[t]
        let target = focusPane(in: current)
        zoomedPanes.removeValue(forKey: item.id)
        let next = UUID()
        if let pid = views[target]?.process.shellPid { splitDirectories[next] = PaneSession.directory(pid: pid) }
        data.projects[p].terminals[t].layout = current.panes.splitting(target, with: next, vertical: vertical)
        paneFocusByTab[item.id] = next
    }

    func requestClosePane(_ id: UUID, item: TerminalItem, projectID: UUID) {
        guard confirm("close pane?", "its running shell and commands will be stopped.") else { return }
        closePane(id, item: item, projectID: projectID)
    }

    func togglePaneZoom(in item: TerminalItem) {
        guard item.panes.ids.count > 1 else { return }
        let id = focusPane(in: item)
        zoomedPanes[item.id] = zoomedPanes[item.id] == nil ? id : nil
        showPane(id, in: item)
    }

    func cyclePane(_ offset: Int, in item: TerminalItem) {
        let ids = item.panes.ids
        guard ids.count > 1, let index = ids.firstIndex(of: focusPane(in: item)) else { return }
        showPane(ids[(index + offset + ids.count) % ids.count], in: item)
    }

    func movePaneFocus(_ direction: PaneDirection, in item: TerminalItem) {
        guard zoomedPanes[item.id] == nil else { return }
        let id = focusPane(in: item)
        guard let window = views[id]?.window else { return }
        let frames = item.panes.ids.compactMap { id -> (UUID, CGRect)? in
            guard let view = views[id], view.window === window else { return nil }
            return (id, view.convert(view.bounds, to: nil))
        }
        if let next = direction.neighbor(from: id, in: frames) { showPane(next, in: item) }
    }

    func resizePane(_ direction: PaneDirection, in item: TerminalItem) {
        let id = focusPane(in: item)
        guard let divider = item.panes.divider(for: id, vertical: direction.vertical) else { return }
        zoomedPanes.removeValue(forKey: item.id)
        paneAdjustment = PaneAdjustment(divider: divider, points: direction.resizePoints)
    }

    func equalizePanes() {
        paneAdjustment = PaneAdjustment(divider: nil, points: 0)
    }

    func showPane(_ id: UUID, in item: TerminalItem) {
        guard item.panes.ids.contains(id) else { return }
        if zoomedPanes[item.id] != nil { zoomedPanes[item.id] = id }
        selected = item.id
        paneFocus = id
        if let view = views[id] { view.window?.makeFirstResponder(view) }
    }

    private func closePane(_ id: UUID, item: TerminalItem, projectID: UUID, shellExited: Bool = false) {
        guard let p = data.projects.firstIndex(where: { $0.id == projectID }),
              let t = data.projects[p].terminals.firstIndex(where: { $0.id == item.id }) else { return }
        let layout = data.projects[p].terminals[t].panes
        guard layout.ids.contains(id) else { return }
        let focused = paneFocusByTab[item.id] ?? layout.firstID
        stopPane(id, shellExited: shellExited)
        if zoomedPanes[item.id] == id || layout.ids.count <= 2 { zoomedPanes.removeValue(forKey: item.id) }
        if let remaining = layout.removing(id) {
            if focused == id { paneFocusByTab[item.id] = remaining.firstID }
            data.projects[p].terminals[t].layout = remaining
        } else {
            removeTab(item.id, projectID: projectID)
        }
    }

    private func stopPane(_ id: UUID, shellExited: Bool = false) {
        activity.removeValue(forKey: id)
        paneDirectories.removeValue(forKey: id)
        splitDirectories.removeValue(forKey: id)
        processes.removeValue(forKey: id)
        runningJobs.removeValue(forKey: id)
        if let view = views.removeValue(forKey: id), !shellExited, view.process.running {
            PaneSession.stopJobs(shell: view.process.shellPid)
            view.process.terminate()
        }
    }

    func stopAllPanes() {
        for id in Array(views.keys) { stopPane(id) }
    }

    func removeProject(_ project: Project) {
        guard confirm("remove \(project.name)?", "its terminals will be stopped. project files will not be deleted.") else { return }
        guard let current = data.projects.first(where: { $0.id == project.id }) else { return }
        for item in current.terminals {
            item.panes.ids.forEach { stopPane($0) }
            zoomedPanes.removeValue(forKey: item.id)
            paneFocusByTab.removeValue(forKey: item.id)
        }
        data.projects.removeAll { $0.id == current.id }
        if current.terminals.contains(where: { $0.id == selected }) { selected = data.firstTerminalID }
    }
}

func confirm(_ message: String, _ info: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = info
    alert.alertStyle = .warning
    alert.addButton(withTitle: "remove")
    alert.addButton(withTitle: "cancel")
    return alert.runModal() == .alertFirstButtonReturn
}

func askName(_ title: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    let field = NSTextField(string: initial)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "save")
    alert.addButton(withTitle: "cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView
    var focus = true

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        let needsFocus = focus && !coordinator.wasFocused
        coordinator.wasFocused = focus
        guard needsFocus || view.superview !== container else { return }
        // A collapse can create the replacement host before dismantling the old one.
        DispatchQueue.main.async { [weak view, weak container, weak coordinator] in
            guard let view, let container, let coordinator, !coordinator.dismantled,
                  let window = container.window else { return }
            let moved = view.superview !== container
            if moved {
                view.removeFromSuperview()
                view.frame = container.bounds
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
            }
            if coordinator.wasFocused && (needsFocus || moved) { window.makeFirstResponder(view) }
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        coordinator.dismantled = true
        container.subviews.forEach { $0.removeFromSuperview() }
    }

    final class Coordinator {
        var wasFocused = false
        var dismantled = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
}

private let processLogos: [String: NSImage] = [
    "pi": "pi-svg.svg", "claude code": "claude-color.svg", "codex": "chatgpt.svg",
    "deepseek": "deepseek-color.svg", "grok": "grok.svg", "babuska": "babuska.png",
    "pnpm": "pnpm.svg", "bun": "bun.svg", "uv": "uv.svg.webp", "ngrok": "ngrok-n-white.svg", "go": "go.svg"
].compactMapValues { file in
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("assets/\(file)") else { return nil }
    guard url.pathExtension == "svg" else { return NSImage(contentsOf: url) }
    guard let svg = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    // CoreSVG does not inherit a font size or text color from a browser.
    let artwork = svg.replacingOccurrences(of: "\"1em\"", with: "\"24\"")
        .replacingOccurrences(of: "currentColor", with: "#ffffff")
    return NSImage(data: Data(artwork.utf8))
}

private func terminalIcon(process: String?, size: CGFloat) -> some View {
    Group {
        if let process, let logo = processLogos[process] {
            Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
                .frame(width: 14, height: 14)
        } else if let process {
            Image(systemName: AgentProcesses.isAgent(process) ? "sparkles" : process == "server" ? "server.rack" : "gearshape")
        } else {
            Text(">_")
        }
    }
    .font(.system(size: size, weight: .semibold, design: .monospaced))
    .modifier(HoverName(name: process.map { "\($0) is running" } ?? "terminal"))
}

private struct HoverNameKey: PreferenceKey {
    static let defaultValue: (String, Anchor<CGRect>)? = nil

    static func reduce(value: inout Value, nextValue: () -> Value) {
        if let next = nextValue() { value = next }
    }
}

private struct HoverName: ViewModifier {
    let name: String
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(name)
            .onHover { hovering = $0 }
            .anchorPreference(key: HoverNameKey.self, value: .bounds) { hovering ? (name, $0) : nil }
    }
}

struct ProjectRow: View {
    @ObservedObject var store: Store
    let project: Project
    @Binding var expanded: Bool
    @State private var headerHovered = false
    @State private var hoveredTerminal: UUID?
    private var chromeColor: SwiftUI.Color { store.windowPalette.chrome }

    private var directoryLabel: String {
        (project.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Button { expanded.toggle() } label: {
                    Text(project.name).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(chromeColor.opacity(0.82)).lineLimit(1)
                }
                .buttonStyle(.plain).help(project.path)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Button { store.addTerminal(projectID: project.id); expanded = true } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 21, height: 20).contentShape(Rectangle())
                    }
                    .modifier(HoverName(name: "new tab"))
                    Button { expanded.toggle() } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(chromeColor.opacity(0.82))
                            .frame(width: 21, height: 20).contentShape(Rectangle())
                    }
                    .modifier(HoverName(name: expanded ? "collapse project" : "expand project"))
                }
                .buttonStyle(.plain)
                .opacity(headerHovered || !expanded ? 1 : 0)
                .allowsHitTesting(headerHovered || !expanded)
                .accessibilityHidden(!headerHovered && expanded)
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.top, 6).padding(.bottom, 3)
            .contentShape(Rectangle())
            .onHover { headerHovered = $0 }
            .contextMenu {
                Button("new terminal") { store.addTerminal(projectID: project.id); expanded = true }
                Button("rename project") { store.renameProject(project) }
                Button("move up") { store.data.moveProject(id: project.id, by: -1) }
                Button("move down") { store.data.moveProject(id: project.id, by: 1) }
                Button("remove project", role: .destructive) { store.removeProject(project) }
            }
            if expanded {
                ForEach(project.terminals) { item in
                    Button { store.selected = item.id } label: {
                        HStack(spacing: 7) {
                            terminalIcon(process: store.processName(in: item), size: 8)
                                .foregroundStyle(Color(red: 0.57, green: 0.87, blue: 0.47))
                                .frame(width: 19, height: 16)
                                .background(.linearGradient(colors: [Color(white: 0.31), Color(white: 0.15)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.18)).allowsHitTesting(false))
                            HStack(spacing: 4) {
                                Text(item.name).lineLimit(1).layoutPriority(1)
                                Text(directoryLabel).foregroundStyle(chromeColor.opacity(0.66))
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(store.selected == item.id ? store.windowPalette.ink : chromeColor)
                        .padding(.trailing, hoveredTerminal == item.id ? 22 : 0)
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(store.selected == item.id ? store.windowPalette.selected : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(store.selected == item.id ? store.windowPalette.ink.opacity(0.16) : .clear).allowsHitTesting(false))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(item.name) — \(store.status(item.id))")
                    .overlay(alignment: .trailing) {
                        if hoveredTerminal == item.id {
                            Button { store.removeTerminal(item, projectID: project.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                    .frame(width: 24, height: 26).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(chromeColor)
                            .modifier(HoverName(name: "close \(item.name)"))
                            .padding(.trailing, 4)
                        }
                    }
                    .onHover { inside in
                        if inside { hoveredTerminal = item.id }
                        else if hoveredTerminal == item.id { hoveredTerminal = nil }
                    }
                    .contextMenu {
                        Button("rename") { store.rename(item, projectID: project.id) }
                        Button("move up") { store.data.moveTerminal(id: item.id, projectID: project.id, by: -1) }
                        Button("move down") { store.data.moveTerminal(id: item.id, projectID: project.id, by: 1) }
                        Button("close", role: .destructive) { store.removeTerminal(item, projectID: project.id) }
                    }
                }
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var sidebarVisible = true
    @State private var collapsedProjects: Set<UUID> = []
    @State private var processesVisible = false
    private var palette: WindowPalette { store.windowPalette }
    private var chromeColor: SwiftUI.Color { palette.chrome }
    private var panelColor: SwiftUI.Color { palette.panel }
    private var sidebarColor: SwiftUI.Color { palette.sidebar }
    private var listingProcesses: Bool { sidebarVisible && processesVisible }
    @State private var inspectedPID: Int32?
    @State private var commandVisible = false
    @State private var commandSearch = ""
    @State private var sessionPickerVisible = false
    @State private var sessionPickerError: String?
    private func openGitChanges() {
        guard let project = selectedProject else { return }
        store.gitChanges = GitChangesRequest(path: project.path, scope: .unstaged)
    }
    @FocusState private var searching: Bool

    private var selectedProject: Project? {
        store.data.projects.first { project in project.terminals.contains { $0.id == store.selected } }
    }

    private func command(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            commandVisible = false
            action()
        } label: {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).frame(height: 27)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var commandMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("search commands, projects, and terminals…", text: $commandSearch)
                    .textFieldStyle(.plain).focused($searching)
            }
            .padding(.horizontal, 8).frame(height: 29)
            .background(palette.ink.opacity(0.075), in: RoundedRectangle(cornerRadius: 7))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if commandSearch.isEmpty || ["open new session", "new project"].contains(where: { $0.localizedCaseInsensitiveContains(commandSearch) }) {
                        command("open new session…") { sessionPickerVisible = true }
                    }
                    if selectedProject != nil, commandSearch.isEmpty || "git changes diff".localizedCaseInsensitiveContains(commandSearch) {
                        command("git changes…", action: openGitChanges)
                    }
                    if let project = selectedProject, commandSearch.isEmpty || "new terminal".contains(commandSearch.lowercased()) {
                        command("new terminal") { store.addTerminal(projectID: project.id) }
                    }
                    if commandSearch.isEmpty || "previous terminal".contains(commandSearch.lowercased()) {
                        command("previous terminal") { store.selectRelative(-1) }
                    }
                    if commandSearch.isEmpty || "next terminal".contains(commandSearch.lowercased()) {
                        command("next terminal") { store.selectRelative(1) }
                    }
                    if let project = selectedProject, let item = project.terminals.first(where: { $0.id == store.selected }) {
                        if item.panes.ids.count > 1 {
                            splitCommands(item)
                        }
                        if commandSearch.isEmpty || "export scrollback".localizedCaseInsensitiveContains(commandSearch) {
                            command("export scrollback…") { store.exportScrollback(in: item) }
                        }
                        if commandSearch.isEmpty || "rename project".contains(commandSearch.lowercased()) {
                            command("rename project…") { store.renameProject(project) }
                        }
                        if commandSearch.isEmpty || "rename terminal".contains(commandSearch.lowercased()) {
                            command("rename terminal…") { store.rename(item, projectID: project.id) }
                        }
                        if commandSearch.isEmpty || "close terminal".contains(commandSearch.lowercased()) {
                            command("close terminal") { store.removeTerminal(item, projectID: project.id) }
                        }
                    }
                    if commandSearch.isEmpty || "increase font size".contains(commandSearch.lowercased()) {
                        command("increase font size") { store.fontSize = min(32, store.fontSize + 1) }
                    }
                    if commandSearch.isEmpty || "decrease font size".contains(commandSearch.lowercased()) {
                        command("decrease font size") { store.fontSize = max(8, store.fontSize - 1) }
                    }
                    ForEach(store.data.projects) { project in
                        ForEach(project.terminals.filter { commandSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(commandSearch) || project.name.localizedCaseInsensitiveContains(commandSearch) }) { item in
                            command("\(project.name) / \(item.name)") { store.selected = item.id }
                        }
                    }
                }
            }
        }
        .font(.system(size: 13))
        .padding(5).frame(width: 328, height: 495)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(palette.keepsOriginalMaterials ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(palette.panel))
        }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(palette.ink.opacity(0.13)).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
        .onAppear { commandSearch = ""; searching = true }
    }

    @ViewBuilder
    private func terminalShortcuts(_ item: TerminalItem, project: Project) -> some View {
        Button("new terminal") { store.addTerminal(projectID: project.id) }.keyboardShortcut(store.shortcut("new terminal"))
        Button("previous pane") { store.cyclePane(-1, in: item) }.keyboardShortcut(store.shortcut("previous pane"))
        Button("next pane") { store.cyclePane(1, in: item) }.keyboardShortcut(store.shortcut("next pane"))
        Button("find in terminal") { store.find(.showFindInterface, in: item) }.keyboardShortcut(store.shortcut("find in terminal"))
        Button("find selection") { store.find(.setSearchString, in: item) }.keyboardShortcut(store.shortcut("find selection"))
        Button("hide find") { store.find(.hideFindInterface, in: item) }.keyboardShortcut(store.shortcut("hide find"))
        Button("next match") { store.find(.nextMatch, in: item) }.keyboardShortcut(store.shortcut("next match"))
        Button("previous match") { store.find(.previousMatch, in: item) }.keyboardShortcut(store.shortcut("previous match"))
        Button("previous prompt") { store.jumpToPrompt(forward: false, in: item) }.keyboardShortcut(store.shortcut("previous prompt"))
        Button("next prompt") { store.jumpToPrompt(forward: true, in: item) }.keyboardShortcut(store.shortcut("next prompt"))
    }

    @ViewBuilder
    private func splitCommands(_ item: TerminalItem) -> some View {
        let zoomTitle = store.zoomedPanes[item.id] == nil ? "zoom pane" : "restore splits"
        if commandSearch.isEmpty || zoomTitle.localizedCaseInsensitiveContains(commandSearch) {
            command(zoomTitle) { store.togglePaneZoom(in: item) }
        }
        if commandSearch.isEmpty || "equalize splits".localizedCaseInsensitiveContains(commandSearch) {
            command("equalize splits") { store.equalizePanes() }
        }
    }

    private func panes(_ layout: PaneLayout, project: Project, focus: UUID?, zoom: UUID?) -> AnyView {
        switch layout {
        case .shell(let id):
            return AnyView(TerminalHost(view: store.terminal(id, project: project), focus: focus == id && !commandVisible)
                .id(id).padding(.leading, 9).padding(.top, 1))
        case .split(let vertical, let first, let second):
            let weight = CGFloat(first.weight(vertical: vertical))
            return AnyView(PaneSplit(vertical: vertical,
                                     first: panes(first, project: project, focus: focus, zoom: zoom),
                                     second: panes(second, project: project, focus: focus, zoom: zoom),
                                     zoomFirst: zoom.flatMap { id in
                                         first.ids.contains(id) ? true : second.ids.contains(id) ? false : nil
                                     },
                                     divider: second.firstID,
                                     balancedRatio: weight / (weight + CGFloat(second.weight(vertical: vertical))),
                                     adjustment: store.paneAdjustment))
        }
    }

    private var processSidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                Text("running processes").font(.headline).padding(.horizontal, 10)
                if store.runningJobs.isEmpty {
                    Text("no running commands").foregroundStyle(.secondary).padding(.horizontal, 10)
                }
                ForEach(store.data.projects) { project in
                    if project.terminals.contains(where: { $0.panes.ids.contains { store.runningJobs[$0] != nil } }) {
                        Text(project.name).font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 6)
                        ForEach(project.terminals) { item in
                            ForEach(item.panes.ids, id: \.self) { id in
                                ForEach(store.runningJobs[id] ?? []) { job in
                                    processRow(job, pane: id, item: item)
                                }
                            }
                        }
                    }
                }
                if store.activity.values.contains(where: { !$0.records.isEmpty }) {
                    Divider().padding(.horizontal, 10)
                    Text("program reports").font(.headline).padding(.horizontal, 10)
                    reportedActivity
                }
            }.padding(.vertical, 8)
        }
    }

    private func processRow(_ job: AgentProcesses.Job, pane: UUID, item: TerminalItem) -> some View {
        let expanded = inspectedPID == job.id
        return VStack(alignment: .leading, spacing: 4) {
            Button { inspectedPID = expanded ? nil : job.id } label: {
                HStack(spacing: 8) {
                    if let badge = job.badge {
                        terminalIcon(process: badge, size: 12)
                    } else {
                        Image(systemName: "terminal").accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.badge == "server" ? job.name : job.badge ?? job.name).lineLimit(1)
                        Text("\(item.name) · pid \(job.id)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "details expanded" : "details collapsed")
            if expanded {
                ProcessDetailsView(pid: job.id, pids: AgentProcesses.processTree(root: job.id, jobs: store.runningJobs[pane] ?? []))
                Button("go to terminal") { store.showPane(pane, in: item) }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 10)
    }

    private var reportedActivity: some View {
        Group {
            ForEach(store.data.projects) { project in
                ForEach(project.terminals) { item in
                    ForEach(item.panes.ids, id: \.self) { id in
                        if let activity = store.activity[id] {
                            ForEach(activity.records.reversed()) { record in
                                activityRow(record, title: record.title ?? activity.app(for: record) ?? item.name,
                                            pane: id, item: item)
                            }
                        }
                    }
                }
            }
        }
    }

    private func activityRow(_ record: ActivityRecords.Record, title: String, pane: UUID, item: TerminalItem) -> some View {
        Button { store.showPane(pane, in: item) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(record.message ?? record.state).foregroundStyle(.secondary).lineLimit(2)
                if let progress = record.progress { ProgressView(value: Double(progress), total: 100) }
                else if let kind = record.kind { Text(kind).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func sidebarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).frame(width: 22, height: 24).contentShape(Rectangle())
    }

    private var sidebar: some View {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Button { sidebarVisible.toggle() } label: { sidebarIcon("sidebar.left") }
                            .modifier(HoverName(name: "hide sidebar"))
                        Spacer(minLength: 0)
                        Button {
                            inspectedPID = nil
                            processesVisible.toggle()
                        } label: {
                            sidebarIcon("waveform.path.ecg")
                                .foregroundStyle(processesVisible ? SwiftUI.Color.accentColor : chromeColor)
                        }
                        .modifier(HoverName(name: processesVisible ? "show projects" : "show running processes"))
                        Button { commandVisible.toggle() } label: { sidebarIcon("command") }
                            .modifier(HoverName(name: "command palette"))
                        Button { sessionPickerVisible = true } label: { sidebarIcon("plus") }
                            .modifier(HoverName(name: "open new session"))
                    }
                    .buttonStyle(.plain).foregroundStyle(chromeColor)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.leading, 99).padding(.trailing, 18).frame(height: 49)
                    if processesVisible {
                        processSidebar
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(store.data.projects) { project in
                                    ProjectRow(store: store, project: project, expanded: Binding(
                                        get: { !collapsedProjects.contains(project.id) },
                                        set: { if $0 { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) } }
                                    ))
                                }
                            }.padding(.horizontal, 10)
                        }
                    }
                    HStack {
                        Menu {
                            Label("this mac", systemImage: "laptopcomputer")
                        } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        .modifier(HoverName(name: "host filter"))
                        Spacer()
                        Button(action: openGitChanges) { sidebarIcon("arrow.left.arrow.right") }
                            .buttonStyle(.plain).disabled(selectedProject == nil)
                            .modifier(HoverName(name: "git changes"))
                        if #available(macOS 14, *) {
                            SettingsLink { Image(systemName: "gearshape") }
                                .buttonStyle(.plain).modifier(HoverName(name: "settings"))
                        } else {
                            Button {
                                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                            } label: { Image(systemName: "gearshape") }
                                .buttonStyle(.plain).modifier(HoverName(name: "settings"))
                        }
                        Button { sessionPickerVisible = true } label: { Image(systemName: "rectangle.stack.badge.plus") }
                            .buttonStyle(.plain).modifier(HoverName(name: "open new session"))
                    }
                    .font(.system(size: 14)).foregroundStyle(chromeColor)
                    .padding(.horizontal, 17).frame(height: 49)
                }
                .frame(width: 240)
                .background(sidebarColor)
    }

    private func zoomTabs(_ item: TerminalItem, active: UUID) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(item.panes.ids.enumerated()), id: \.element) { index, id in
                        let selected = id == active
                        Button { store.showPane(id, in: item) } label: {
                            Text("pane \(index + 1)")
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .frame(minWidth: 86, minHeight: 22)
                                .foregroundStyle(selected ? SwiftUI.Color.primary : SwiftUI.Color.secondary)
                                .background {
                                    if selected {
                                        Capsule().fill(palette.ink.opacity(0.14))
                                            .overlay(Capsule().strokeBorder(palette.ink.opacity(0.12)))
                                    }
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(id)
                    }
                }
                .padding(2)
                .background(palette.ink.opacity(0.05), in: Capsule())
            }
            .onAppear { proxy.scrollTo(active) }
            .onChange(of: active) { proxy.scrollTo($0) }
        }
    }

    private var detail: some View {
            Group {
            if let project = store.data.projects.first(where: { $0.terminals.contains(where: { $0.id == store.selected }) }),
               let item = project.terminals.first(where: { $0.id == store.selected }) {
                if !store.directoryExists(project.path) {
                    VStack(spacing: 8) {
                        if !sidebarVisible {
                            Button("show sidebar") { sidebarVisible = true }
                        }
                        Text("project folder not found")
                        Text(project.path).textSelection(.enabled).foregroundStyle(.secondary)
                        Text("restore the folder, or remove and add the project again.").foregroundStyle(.secondary)
                    }.padding()
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            if !sidebarVisible {
                                Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                                    .buttonStyle(.plain).modifier(HoverName(name: "show sidebar"))
                                    .padding(.leading, 81)
                            }
                            terminalIcon(process: store.processName(in: item), size: 14)
                            Text(item.name).lineLimit(1).layoutPriority(1)
                            if let active = store.zoomedPanes[item.id] {
                                zoomTabs(item, active: active)
                            } else {
                                Text(((store.reportedDirectory(in: item) ?? project.path) as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(chromeColor.opacity(0.66)).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            HStack(spacing: 11) {
                                ForEach([false, true], id: \.self) { vertical in
                                    Button { store.split(item, projectID: project.id, vertical: vertical) } label: {
                                        Image(systemName: vertical ? "rectangle.split.1x2" : "rectangle.split.2x1")
                                    }
                                    .keyboardShortcut(store.shortcut(vertical ? "split down" : "split right"))
                                    .modifier(HoverName(name: vertical ? "split down" : "split right"))
                                }
                                if item.panes.ids.count > 1 {
                                    Button { store.togglePaneZoom(in: item) } label: {
                                        let zoomed = store.zoomedPanes[item.id] != nil
                                        Image(systemName: zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass")
                                            .foregroundStyle(zoomed ? SwiftUI.Color.accentColor : chromeColor.opacity(0.65))
                                    }
                                    .keyboardShortcut(store.shortcut("zoom pane"))
                                    .modifier(HoverName(name: store.zoomedPanes[item.id] == nil ? "zoom pane" : "restore splits"))
                                }
                                Button { store.addTerminal(projectID: project.id) } label: { Image(systemName: "rectangle.on.rectangle") }
                                    .modifier(HoverName(name: "new terminal"))
                                Button { sidebarVisible.toggle() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                                    .modifier(HoverName(name: sidebarVisible ? "expand terminal area" : "show sidebar"))
                                Button {
                                    store.requestClosePane(store.focusPane(in: item), item: item, projectID: project.id)
                                } label: { Image(systemName: "xmark") }.modifier(HoverName(name: "close pane"))
                            }
                            .buttonStyle(.plain).foregroundStyle(chromeColor.opacity(0.65))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(panelColor)
                        panes(item.panes, project: project,
                              focus: store.zoomedPanes[item.id] ?? store.paneFocus.flatMap { item.panes.ids.contains($0) ? $0 : nil } ?? item.panes.ids.first,
                              zoom: store.zoomedPanes[item.id])
                            .id(item.id)
                    }
                }
            } else {
                VStack {
                    if !sidebarVisible {
                        HStack {
                            Button { sidebarVisible.toggle() } label: { Image(systemName: "sidebar.left") }
                                .buttonStyle(.plain).modifier(HoverName(name: "show sidebar")).padding(.leading, 91)
                            Spacer()
                        }.frame(height: 46)
                    }
                    Spacer()
                    Text("add a project and select a terminal").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(panelColor)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.ink.opacity(0.1)).allowsHitTesting(false))
            .padding(.vertical, 8).padding(.trailing, 8)
            .padding(.leading, sidebarVisible ? 0 : 8)
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible { sidebar }
            detail
        }
        .ignoresSafeArea(.container, edges: .top)
        .task(id: listingProcesses) { await store.watchProcesses(includeJobs: listingProcesses) }
        .onChange(of: store.data.projects.map(\.id)) { collapsedProjects.formIntersection($0) }
        .onChange(of: commandVisible) { visible in
            guard !visible else { return }
            DispatchQueue.main.async {
                guard !commandVisible, !sessionPickerVisible,
                      let item = selectedProject?.terminals.first(where: { $0.id == store.selected }) else { return }
                store.showPane(store.focusPane(in: item), in: item)
            }
        }
        .allowsHitTesting(!commandVisible)
        .background {
            HStack {
                if !commandVisible, let item = selectedProject?.terminals.first(where: { $0.id == store.selected }), item.panes.ids.count > 1 {
                    ForEach(PaneDirection.allCases, id: \.self) { direction in
                        Button("focus pane \(direction.rawValue)") { store.movePaneFocus(direction, in: item) }
                            .keyboardShortcut(store.shortcut("focus pane \(direction.rawValue)"))
                        Button("resize pane \(direction.rawValue)") { store.resizePane(direction, in: item) }
                            .keyboardShortcut(store.shortcut("resize pane \(direction.rawValue)"))
                    }
                    Button("equalize splits") { store.equalizePanes() }
                        .keyboardShortcut(store.shortcut("equalize splits"))
                }
                if !commandVisible, !sessionPickerVisible, let project = selectedProject,
                   let item = project.terminals.first(where: { $0.id == store.selected }) {
                    terminalShortcuts(item, project: project)
                }
                Button("previous terminal") { store.selectRelative(-1) }.keyboardShortcut(store.shortcut("previous terminal"))
                Button("next terminal") { store.selectRelative(1) }.keyboardShortcut(store.shortcut("next terminal"))
                Button("command palette") { commandVisible.toggle() }.keyboardShortcut(store.shortcut("command palette"))
                Button("open new session") {
                    commandVisible = false
                    sessionPickerVisible = true
                }.keyboardShortcut(store.shortcut("open new session"))
            }.opacity(0).accessibilityHidden(true)
        }
        .background { sidebarColor.ignoresSafeArea() }
        .overlayPreferenceValue(HoverNameKey.self) { hover in
            if let (name, anchor) = hover, !commandVisible, !sessionPickerVisible {
                GeometryReader { proxy in
                    let bounds = proxy[anchor]
                    Text(name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 23)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .frame(width: 160)
                        .position(
                            x: min(max(bounds.midX, 84), proxy.size.width - 84),
                            y: bounds.maxY + 30 > proxy.size.height ? bounds.minY - 17 : bounds.maxY + 17
                        )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .top) {
            if commandVisible {
                ZStack(alignment: .top) {
                    Button { commandVisible = false } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                    commandMenu.padding(.top, 83)
                }
                .onExitCommand { commandVisible = false }
            }
        }
        .fileImporter(isPresented: $sessionPickerVisible, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                store.openProject(url)
                if let selectedProject { collapsedProjects.remove(selectedProject.id) }
                sidebarVisible = true
                inspectedPID = nil
                processesVisible = false
            case .failure(let error):
                sessionPickerError = error.localizedDescription
            }
        }
        .alert("could not open session", isPresented: Binding(
            get: { sessionPickerError != nil },
            set: { if !$0 { sessionPickerError = nil } }
        )) {
            Button("ok") { sessionPickerError = nil }
        } message: {
            Text(sessionPickerError ?? "")
        }
        .preferredColorScheme(palette.scheme)
        .frame(minWidth: 700, minHeight: 450)
    }
}

struct ConfirmWindowClose: NSViewRepresentable {
    var requestQuit: @MainActor () -> Void = { NSApp.terminate(nil) }

    func makeNSView(context: Context) -> CloseView { CloseView(requestQuit: requestQuit) }
    func updateNSView(_ view: CloseView, context: Context) {}

    final class CloseView: NSView {
        private let closeDelegate: CloseDelegate

        init(requestQuit: @escaping @MainActor () -> Void) {
            closeDelegate = CloseDelegate(requestQuit: requestQuit)
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let window, window.delegate !== closeDelegate else { return }
                closeDelegate.original = window.delegate
                window.delegate = closeDelegate
            }
        }
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var original: NSWindowDelegate?
        let requestQuit: @MainActor () -> Void

        init(requestQuit: @escaping @MainActor () -> Void) { self.requestQuit = requestQuit }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // Keep the window open while the app's quit confirmation is pending.
            DispatchQueue.main.async { [requestQuit] in requestQuit() }
            return false
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor lazy var quickTerminal = QuickTerminal()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: GPUPane.handleDeleteShortcut)
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        .banner
    }

    var onQuit: (() -> Void)?
    private var ghosttyWindow: NSWindow?

    @MainActor func openGhosttyPreview(directory: String) {
        if let ghosttyWindow, ghosttyWindow.isVisible || ghosttyWindow.isMiniaturized {
            if ghosttyWindow.isMiniaturized { ghosttyWindow.deminiaturize(nil) }
            ghosttyWindow.makeKeyAndOrderFront(nil)
            return
        }
        let frame = NSRect(x: 0, y: 0, width: 820, height: 500)
        guard let view = GhosttyPreview(previewFrame: frame) else {
            let alert = NSAlert()
            alert.messageText = "could not start the libghostty preview"
            alert.runModal()
            return
        }
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "libghostty preview"
        window.contentMinSize = NSSize(width: 240, height: 120)
        window.contentView = view
        window.delegate = view
        ghosttyWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.start(directory: directory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let alert = NSAlert()
        alert.messageText = "quit senterm?"
        alert.informativeText = "running terminals and their commands will stop."
        alert.addButton(withTitle: "quit")
        alert.addButton(withTitle: "cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        (ghosttyWindow?.contentView as? GhosttyPreview)?.stop()
        onQuit?()
        return .terminateNow
    }
}

@main
enum SenTermMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.first == "review" else {
            SenTermApp.main()
            return
        }
        guard args == ["review", "list"] else {
            fputs("usage: senterm review list\n", stderr)
            exit(2)
        }
        do {
            let json = try DiffReview.list(in: FileManager.default.currentDirectoryPath)
            FileHandle.standardOutput.write(json)
            print()
        } catch {
            fputs("senterm: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct SenTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()
    @AppStorage("quickTerminalEnabled") private var quickTerminalEnabled = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("senterm", id: "main") {
            ContentView(store: store)
                .background { ConfirmWindowClose().allowsHitTesting(false) }
                .onAppear {
                    delegate.onQuit = { [weak store] in store?.stopAllPanes() }
                    delegate.quickTerminal.show = { [openWindow] in
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "main")
                    }
                    delegate.quickTerminal.setEnabled(quickTerminalEnabled)
                }
                .onChange(of: quickTerminalEnabled) { delegate.quickTerminal.setEnabled($0) }
                .onChange(of: store.gitChanges) { request in
                    if let request { openWindow(id: "git-changes", value: request) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1178, height: 758)
        .commands {
            CommandGroup(after: .newItem) {
                Button("open libghostty preview…") {
                    let directory = store.data.projects.first { project in
                        project.terminals.contains { $0.id == store.selected }
                    }?.path
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    delegate.openGhosttyPreview(directory: directory.flatMap { store.directoryExists($0) ? $0 : nil } ?? home)
                }
            }
        }
        WindowGroup("git changes", id: "git-changes", for: GitChangesRequest.self) { $request in
            Group {
                if let request {
                    GitChangesView(directory: request.path, initialScope: request.scope, palette: store.windowPalette)
                } else {
                    Text("run git diff in a senterm terminal to review changes here.")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 760, minHeight: 470)
                }
            }
            .preferredColorScheme(store.windowPalette.scheme)
        }
        .defaultSize(width: 1210, height: 760)

        Settings {
            ThemeSettings(selection: $store.theme, fontSize: $store.fontSize,
                          imported: $store.importedTheme, shortcuts: $store.shortcutText,
                          scrollbackLines: $store.scrollbackLines)
        }
    }
}
