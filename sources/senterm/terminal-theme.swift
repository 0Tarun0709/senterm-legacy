import SwiftUI
import UserNotifications
import SwiftTerm

enum TerminalTheme: String, CaseIterable {
    case contrast = "high contrast"
    case ocean = "ocean"
    case paper = "paper"
    case original = "original"

    var background: NSColor {
        switch self {
        case .contrast: color(0x101217)
        case .ocean: color(0x10202c)
        case .paper: color(0xfaf6ed)
        case .original: color(0x0d1015)
        }
    }

    var foreground: NSColor {
        switch self {
        case .contrast: color(0xf0f3fa)
        case .ocean: color(0xe0eef5)
        case .paper: color(0x27221d)
        case .original: NSColor(srgbRed: 0.88, green: 0.90, blue: 0.92, alpha: 1)
        }
    }

    private var cursor: NSColor {
        switch self {
        case .paper: color(0x1243a3)
        case .original: NSColor(srgbRed: 0.25, green: 0.49, blue: 0.91, alpha: 1)
        default: color(0x89b4ff)
        }
    }

    var palette: [SwiftTerm.Color] {
        let rgb: [UInt32] = switch self {
        case .contrast: [
            0x373e49, 0xff727f, 0x72e49c, 0xffd56d, 0x79adff, 0xd8a3ff, 0x69e4ea, 0xe2e8f2,
            0x8693a6, 0xff939e, 0x99f2b7, 0xffe4a0, 0xa2c6ff, 0xe7c0ff, 0x9ef1f4, 0xffffff
        ]
        case .ocean: [
            0x283f4c, 0xf58b91, 0x7cdbba, 0xf1cf8a, 0x82bcee, 0xc4a7e7, 0x69cdd7, 0xcde2ec,
            0x7797a5, 0xffa7ab, 0x9eead0, 0xffe0a6, 0xa6d2f4, 0xddc2f6, 0x95e9eb, 0xecf7fb
        ]
        case .paper: [
            0x29231d, 0xa32139, 0x24633c, 0x815400, 0x204e98, 0x7d407d, 0x16626d, 0x514943,
            0x6b6258, 0xba3453, 0x236e40, 0x876000, 0x2d57a3, 0x895196, 0x146d79, 0x70675d
        ]
        case .original: []
        }
        if self == .original { return SwiftTerm.Color.defaultInstalledColors }
        return rgb.map {
            SwiftTerm.Color(red8: UInt16(($0 >> 16) & 255), green8: UInt16(($0 >> 8) & 255), blue8: UInt16($0 & 255))
        }
    }

    func apply(to view: TerminalView, imported: GhosttyTheme? = nil) {
        func custom(_ name: String) -> NSColor? { imported?.colors[name].map(color) }
        view.nativeBackgroundColor = custom("background") ?? background
        view.nativeForegroundColor = custom("foreground") ?? foreground
        view.caretColor = custom("cursor-color") ?? cursor
        view.caretTextColor = custom("cursor-text")
        view.selectedTextBackgroundColor = custom("selection-background") ?? NSColor(srgbRed: 0, green: 166.0 / 255, blue: 178.0 / 255, alpha: 1)
        view.selectedTextForegroundColor = custom("selection-foreground") ?? .black
        var ansi = palette
        for (index, rgb) in imported?.palette ?? [:] where ansi.indices.contains(index) {
            ansi[index] = SwiftTerm.Color(red8: UInt16((rgb >> 16) & 255), green8: UInt16((rgb >> 8) & 255), blue8: UInt16(rgb & 255))
        }
        view.installColors(ansi)
    }

    private func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

struct ThemeSettings: View {
    @Binding var selection: TerminalTheme
    @Binding var fontSize: Double
    @Binding var imported: GhosttyTheme?
    @Binding var shortcuts: String
    @Binding var scrollbackLines: Int
    @AppStorage("quickTerminalEnabled") private var quickTerminalEnabled = false
    @AppStorage("commandNotifications") private var commandNotifications = false
    @State private var notificationsUnavailable = false
    @AppStorage("disableZshIntegration") private var disableZshIntegration = false
    @State private var importFailed = false
    @State private var section = Section.themes

    private enum Section: String, CaseIterable {
        case themes, terminal, shortcuts

        var icon: String {
            switch self {
            case .themes: "paintpalette.fill"
            case .terminal: "terminal.fill"
            case .shortcuts: "command"
            }
        }
    }

    private var windowPalette: WindowPalette { WindowPalette(theme: selection, imported: imported) }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("settings")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                ForEach(Section.allCases, id: \.self) { item in
                    Button { section = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                windowPalette.ink.opacity(section == item ? 0.09 : 0),
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 175)
            .background(windowPalette.settingsSidebar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(section.rawValue).font(.title2.bold())
                    switch section {
                    case .themes:
                        themes
                    case .terminal:
                        Stepper(value: $fontSize, in: 8...32, step: 1) {
                            Text("font size: \(Int(fontSize)) pt")
                        }
                        Stepper(value: $scrollbackLines, in: 500...100_000, step: 500) {
                            Text("scrollback: \(scrollbackLines) lines")
                        }
                        Toggle("automatic zsh integration", isOn: Binding(
                            get: { !disableZshIntegration }, set: { disableZshIntegration = !$0 }
                        ))
                        Text("applies to new terminals. does not edit your shell files.")
                            .foregroundStyle(.secondary)
                        Toggle("quick terminal (control-option-t)", isOn: $quickTerminalEnabled)
                        Toggle("long command notifications", isOn: $commandNotifications)
                            .onChange(of: commandNotifications) { enabled in
                                guard enabled else { return }
                                Task { @MainActor in
                                    let allowed = (try? await UNUserNotificationCenter.current()
                                        .requestAuthorization(options: [.alert])) ?? false
                                    if !allowed { commandNotifications = false; notificationsUnavailable = true }
                                }
                            }
                            .alert("notifications unavailable", isPresented: $notificationsUnavailable) {
                                Button("ok", role: .cancel) {}
                            } message: {
                                Text("check senterm in system settings → notifications.")
                            }
                        Text("for zsh commands that take at least 10 seconds in an inactive pane.")
                            .foregroundStyle(.secondary)
                    case .shortcuts:
                        ShortcutSettings(saved: $shortcuts)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
        .frame(width: 730, height: 480)
        .background(windowPalette.settingsPanel)
        .preferredColorScheme(windowPalette.scheme)
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("import ghostty theme…", action: importTheme)
                if let imported {
                    Text(imported.name).lineLimit(1)
                    Button("use preset") { self.imported = nil }
                }
            }
            .alert("could not read a ghostty theme", isPresented: $importFailed) {
                Button("ok", role: .cancel) {}
            }
            Text("themes apply to open windows and terminals without restarting them.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(TerminalTheme.allCases, id: \.self) { theme in
                    Button { selection = theme; imported = nil } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(theme.rawValue).fontWeight(.medium)
                                Spacer()
                                Image(systemName: selection == theme && imported == nil ? "checkmark.circle.fill" : "circle")
                            }
                            preview(theme)
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.rawValue)
                    .accessibilityAddTraits(selection == theme && imported == nil ? .isSelected : [])
                }
            }
            Text("these colors apply to ansi output. your shell or app still decides what to highlight.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        let themes = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/Resources/ghostty/themes")
        if FileManager.default.fileExists(atPath: themes.path) { panel.directoryURL = themes }
        guard panel.runModal() == .OK, let file = panel.url else { return }
        guard let handle = try? FileHandle(forReadingFrom: file) else { importFailed = true; return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
              let text = String(data: data, encoding: .utf8),
              let theme = GhosttyTheme(name: file.lastPathComponent, text: text) else {
            importFailed = true
            return
        }
        imported = theme
    }

    private func preview(_ theme: TerminalTheme) -> some View {
        let colors = theme.palette.map {
            SwiftUI.Color(nsColor: NSColor(srgbRed: CGFloat($0.red) / 65535, green: CGFloat($0.green) / 65535,
                                           blue: CGFloat($0.blue) / 65535, alpha: 1))
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(SwiftUI.Color(nsColor: theme.foreground))
                Text("echo").foregroundStyle(colors[2])
                Text(" 'hello'").foregroundStyle(colors[3])
            }
            Text("command not found").foregroundStyle(colors[1])
            HStack(spacing: 3) {
                ForEach(0..<8) { index in
                    RoundedRectangle(cornerRadius: 2).fill(colors[index]).frame(height: 9)
                }
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SwiftUI.Color(nsColor: theme.background), in: RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}
