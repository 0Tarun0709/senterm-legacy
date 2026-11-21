import SwiftUI

struct TerminalShortcuts {
    static let defaults = [
        "new terminal": "cmd+t", "previous pane": "cmd+[", "next pane": "cmd+]",
        "find in terminal": "cmd+f", "find selection": "cmd+e", "hide find": "cmd+shift+f",
        "next match": "cmd+g", "previous match": "cmd+shift+g",
        "previous prompt": "cmd+up", "next prompt": "cmd+down",
        "split right": "cmd+d", "split down": "cmd+shift+d", "zoom pane": "cmd+shift+return",
        "focus pane left": "cmd+option+left", "focus pane right": "cmd+option+right",
        "focus pane up": "cmd+option+up", "focus pane down": "cmd+option+down",
        "resize pane left": "cmd+ctrl+left", "resize pane right": "cmd+ctrl+right",
        "resize pane up": "cmd+ctrl+up", "resize pane down": "cmd+ctrl+down",
        "equalize splits": "cmd+ctrl+=", "previous terminal": "cmd+shift+[", "next terminal": "cmd+shift+]",
        "command palette": "cmd+shift+p", "open new session": "cmd+shift+n"
    ]

    static func parse(_ text: String) -> [String: String]? {
        var result = defaults
        var edited: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard fields.count == 2, defaults[fields[0]] != nil, edited.insert(fields[0]).inserted,
                  fields[1] == "none" || binding(fields[1]) != nil else { return nil }
            result[fields[0]] = fields[1]
        }
        let active = result.values.filter { $0 != "none" }.map { $0.split(separator: "+").sorted().joined(separator: "+") }
        return Set(active).count == active.count ? result : nil
    }

    static func binding(_ text: String) -> KeyboardShortcut? {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
        guard parts.count > 1, let last = parts.last else { return nil }
        var modifiers: EventModifiers = []
        for part in parts.dropLast() {
            let modifier: EventModifiers
            switch part {
            case "cmd": modifier = .command
            case "ctrl": modifier = .control
            case "option": modifier = .option
            case "shift": modifier = .shift
            default: return nil
            }
            guard !modifiers.contains(modifier) else { return nil }
            modifiers.insert(modifier)
        }
        guard modifiers.contains(.command) else { return nil }
        let key: KeyEquivalent
        switch last {
        case "up": key = .upArrow
        case "down": key = .downArrow
        case "left": key = .leftArrow
        case "right": key = .rightArrow
        case "return": key = .return
        case "space": key = .space
        default:
            guard last.count == 1, let char = last.first, char.isASCII, !char.isWhitespace else { return nil }
            key = KeyEquivalent(char)
        }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}

struct ShortcutSettings: View {
    @Binding var saved: String
    @State private var draft = ""
    @State private var invalid = false

    private static let template = TerminalShortcuts.defaults.sorted { $0.key < $1.key }
        .map { "\($0.key) = \($0.value)" }.joined(separator: "\n")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("edit a shortcut, or set it to none. use cmd with optional shift, option, or ctrl.")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(height: 275)
                .accessibilityLabel("keyboard shortcut assignments")
            HStack {
                Button("save") {
                    guard TerminalShortcuts.parse(draft) != nil else { invalid = true; return }
                    saved = draft
                    invalid = false
                }
                Button("restore defaults") { saved = ""; draft = Self.template; invalid = false }
                if invalid { Text("check for invalid or duplicate shortcuts.").foregroundStyle(.red) }
            }
        }
        .onAppear { draft = saved.isEmpty ? Self.template : saved }
    }
}
