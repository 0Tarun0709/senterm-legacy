import Foundation

enum AgentProcesses {
    struct Job: Identifiable, Equatable, Sendable {
        let id: Int32
        let parent: Int32
        let name: String
        var badge: String?
    }

    struct Details: Sendable {
        let cpu: Double
        let residentKiB: Int64
        let elapsed: String
        let listeners: [String]
    }

    static func details(pid: Int32, including pids: Set<Int32>) -> Details? {
        guard let stats = parseUsage(output(from: "/bin/ps", arguments: ["-p", String(pid), "-o", "%cpu=,rss=,etime="])) else { return nil }
        let ids = pids.union([pid]).map { String($0) }.joined(separator: ",")
        let sockets = output(from: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", ids, "-Fn"])
        let listeners = Set(sockets.split(separator: "\n").compactMap { line in
            line.first == "n" && line.count > 1 ? String(line.dropFirst()) : nil
        }).sorted()
        return Details(cpu: stats.cpu, residentKiB: stats.residentKiB, elapsed: stats.elapsed, listeners: listeners)
    }

    static func parseUsage(_ output: String) -> (cpu: Double, residentKiB: Int64, elapsed: String)? {
        let fields = output.split(whereSeparator: \.isWhitespace)
        guard fields.count == 3, let cpu = Double(fields[0]),
              let residentKiB = Int64(fields[1]), residentKiB >= 0 else { return nil }
        return (cpu, residentKiB, String(fields[2]))
    }

    static func processTree(root: Int32, jobs: [Job]) -> Set<Int32> {
        let children = Dictionary(grouping: jobs, by: \.parent)
        var found: Set<Int32> = []
        var pending = [root]
        while let pid = pending.popLast() {
            if found.insert(pid).inserted { pending.append(contentsOf: (children[pid] ?? []).map(\.id)) }
        }
        return found
    }

    struct Snapshot: Sendable {
        let badges: [Int32: String]
        let jobs: [Int32: [Job]]
    }
    private static let commands = [
        "pi": "pi", "claude": "claude code", "codex": "codex", "openclaw": "openclaw",
        "opencode": "opencode", "gemini": "gemini cli", "qwen": "qwen code", "aider": "aider",
        "goose": "goose", "amp": "amp", "cursor-agent": "cursor cli", "copilot": "github copilot cli",
        "droid": "factory droid", "kiro-cli": "kiro cli", "kiro-cli-chat": "kiro cli",
        "deepseek": "deepseek", "grok": "grok", "babuska": "babuska"
    ]
    private static let packages = [
        "@earendil-works/pi-coding-agent": "pi", "@mariozechner/pi-coding-agent": "pi",
        "@anthropic-ai/claude-code": "claude code", "@openai/codex": "codex",
        "@google/gemini-cli": "gemini cli", "@qwen-code/qwen-code": "qwen code",
        "@sourcegraph/amp": "amp", "@github/copilot": "github copilot cli",
        "openclaw": "openclaw", "opencode-ai": "opencode"
    ]

    private static let tools = ["pnpm": "pnpm", "bun": "bun", "uv": "uv", "uvx": "uv", "ngrok": "ngrok", "go": "go"]

    static func isAgent(_ name: String) -> Bool {
        name != "server" && !tools.values.contains(name)
    }

    static func hasForegroundJob(shells: Set<Int32>) -> Bool {
        for pid in shells {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
            if info.e_tpgid != UInt32(pid) { return true }
        }
        return false
    }

    static func snapshot(shells: Set<Int32>, includeJobs: Bool, checkIdle: Bool = false) -> Snapshot {
        if checkIdle, !includeJobs, !hasForegroundJob(shells: shells) { return Snapshot(badges: [:], jobs: [:]) }
        let processes = output(from: "/bin/ps", arguments: ["-axww", "-o", "pid=,pgid=,tpgid=,ppid=,stat=,comm=,args="])
        return detect(in: processes, shells: shells, includeJobs: includeJobs) { pids in
            let ids = pids.map { String($0) }.joined(separator: ",")
            let listeners = output(from: "/usr/sbin/lsof", arguments: ["-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", ids, "-Fp"])
            return Set(listeners.split(separator: "\n").compactMap { $0.first == "p" ? Int32($0.dropFirst()) : nil })
        }
    }

    private static func output(from path: String, arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: bytes, as: UTF8.self) : ""
    }

    static func detect(in snapshot: String, shells: Set<Int32>, includeJobs: Bool = false,
                       listeners: (Set<Int32>) -> Set<Int32> = { _ in [] }) -> Snapshot {
        var foreground: [Int32: Int32] = [:]
        var jobs: [Int32: [(pid: Int32, agent: String?, tool: String?)]] = [:]
        var children: [Int32: [Job]] = [:]
        for line in snapshot.split(separator: "\n") {
            let fields = line.split(maxSplits: 6, whereSeparator: \.isWhitespace)
            guard fields.count == 7, let pid = Int32(fields[0]), let group = Int32(fields[1]),
                  let active = Int32(fields[2]), let parent = Int32(fields[3]), fields[4].first != "Z" else { continue }
            if shells.contains(pid) {
                if active > 0 { foreground[pid] = active }
                continue
            }
            let isForeground = active > 0 && group == active
            guard isForeground || includeJobs else { continue }
            let name = basename(fields[5])
            let agent = identify(executable: fields[5], arguments: fields[6])
            let tool = tools[name] ?? (name == "node" ? entryPoint(fields[6]).flatMap { tools[basename($0)] } : nil)
            if isForeground { jobs[group, default: []].append((pid, agent, tool)) }
            if includeJobs { children[parent, default: []].append(Job(id: pid, parent: parent, name: name, badge: agent ?? tool)) }
        }
        var names: [Int32: String] = [:]
        var unknown: [Int32: Int32] = [:]
        for group in Set(foreground.values) {
            guard let members = jobs[group] else { continue }
            let leader = members.first { $0.pid == group }
            names[group] = leader?.agent ?? members.lazy.compactMap(\.agent).first
                ?? leader?.tool ?? members.lazy.compactMap(\.tool).first
            if names[group] == nil {
                for member in members { unknown[member.pid] = group }
            }
        }
        let servers = unknown.isEmpty ? [] : listeners(Set(unknown.keys))
        for pid in servers {
            if let group = unknown[pid] { names[group] = "server" }
        }
        // shortcut: only local descendants are listed; detached or remote jobs need explicit reporting.
        var byShell: [Int32: [Job]] = [:]
        if includeJobs {
            for shell in shells {
                var work = children[shell] ?? []
                var index = 0
                var visited: Set<Int32> = [shell]
                while index < work.count {
                    let job = work[index]
                    if visited.insert(job.id).inserted { work.append(contentsOf: children[job.id] ?? []) }
                    index += 1
                }
                if !work.isEmpty {
                    byShell[shell] = work.sorted { $0.id < $1.id }.map { job in
                        var job = job
                        if servers.contains(job.id) { job.badge = "server" }
                        return job
                    }
                }
            }
        }
        return Snapshot(badges: foreground.compactMapValues { names[$0] }, jobs: byShell)
    }

    private static func identify(executable: Substring, arguments: Substring) -> String? {
        let command = basename(executable)
        if let name = commands[command] { return name }
        if command == "agent", executable.contains("/.cursor/") { return "cursor cli" }
        guard ["node", "bun", "deno", "uv", "uvx"].contains(command) || command.hasPrefix("python") else { return nil }
        let args = arguments.split(maxSplits: 3, whereSeparator: \.isWhitespace)
        guard args.count > 1, basename(args[0]) == command else { return nil }
        if args[1] == "-m", args.count > 2, args[2] == "aider", command.hasPrefix("python") { return "aider" }
        guard let entry = entryPoint(arguments) else { return nil }
        if let name = commands[basename(entry)] { return name }
        if let path = entry.range(of: "node_modules/", options: .backwards)?.upperBound {
            let components = entry[path...].split(separator: "/")
            let count = components.first?.hasPrefix("@") == true ? 2 : 1
            return packages[components.prefix(count).joined(separator: "/")]
        }
        return nil
    }

    private static func entryPoint(_ arguments: Substring) -> Substring? {
        let args = arguments.split(maxSplits: 3, whereSeparator: \.isWhitespace)
        guard args.count > 1 else { return nil }
        let entry = args[1] == "run" && args.count > 2 ? args[2] : args[1]
        return entry.hasPrefix("-") ? nil : entry
    }

    private static func basename(_ path: Substring) -> String {
        String(path.split(separator: "/").last ?? path)
    }
}
