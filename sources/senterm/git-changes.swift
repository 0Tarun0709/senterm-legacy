import Foundation

struct GitChanges {
    enum Scope: String, CaseIterable, Hashable, Codable {
        case unstaged, staged
        var arguments: [String] { self == .staged ? ["--cached"] : [] }
    }

    struct Line: Equatable {
        let number: Int
        let text: String
    }

    struct Row: Equatable {
        var old: Line?
        var new: Line?
        var changed = false
        var startsHunk = false
    }

    // shortcut: highlight one changed span per aligned line; use token diffing if finer highlights are needed.
    static func changedSpans(old: String, new: String) -> (old: Range<String.Index>, new: Range<String.Index>) {
        var left = old.startIndex, right = new.startIndex
        var leftEnd = old.endIndex, rightEnd = new.endIndex
        while left < leftEnd, right < rightEnd, old[left] == new[right] {
            old.formIndex(after: &left)
            new.formIndex(after: &right)
        }
        while left < leftEnd, right < rightEnd {
            let previousLeft = old.index(before: leftEnd), previousRight = new.index(before: rightEnd)
            guard old[previousLeft] == new[previousRight] else { break }
            leftEnd = previousLeft
            rightEnd = previousRight
        }
        return (left..<leftEnd, right..<rightEnd)
    }

    struct Files {
        let root: String
        let gitDirectory: String
        let revision: String?
        let paths: [String]
        let untracked: Set<String>
        let status: [String: String]
    }

    static func files(in directory: String, scope: Scope) throws -> Files {
        let (root, gitDirectory, revision) = try worktree(in: directory)
        let names = try git(["diff", "--name-status", "-z", "--no-ext-diff", "--no-renames"] + scope.arguments + ["--"], in: root)
        let untracked = scope == .unstaged ? try git(["ls-files", "--others", "--exclude-standard", "-z"], in: root) : Data()
        let fields = names.split(separator: 0)
        var status: [String: String] = [:]
        for index in stride(from: 0, to: fields.count - fields.count % 2, by: 2) {
            guard let path = String(bytes: fields[index + 1], encoding: .utf8) else { continue }
            status[path] = String(decoding: fields[index], as: UTF8.self)
        }
        let newPaths = Set(untracked.split(separator: 0).compactMap { String(bytes: $0, encoding: .utf8) }.filter { !$0.hasSuffix("/") })
        for path in newPaths { status[path] = "?" }
        return Files(root: root, gitDirectory: gitDirectory, revision: revision, paths: status.keys.sorted(), untracked: newPaths, status: status)
    }

    static func worktree(in directory: String) throws -> (root: String, gitDirectory: String, revision: String?) {
        let root = String(decoding: try git(["rev-parse", "--show-toplevel"], in: directory).dropLast(), as: UTF8.self)
        let gitDirectory = String(decoding: try git(["rev-parse", "--absolute-git-dir"], in: root).dropLast(), as: UTF8.self)
        let revision: String?
        if let branch = try? git(["symbolic-ref", "--short", "HEAD"], in: root) {
            revision = String(decoding: branch.dropLast(), as: UTF8.self)
        } else if let commit = try? git(["rev-parse", "--short", "HEAD"], in: root) {
            revision = "detached @ " + String(decoding: commit.dropLast(), as: UTF8.self)
        } else {
            revision = nil
        }
        return (root, gitDirectory, revision)
    }

    struct Totals {
        var additions = 0
        var deletions = 0

        mutating func include(_ data: Data) {
            for record in data.split(separator: 0) {
                let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
                // Git reports binary changes as two dashes, not line counts.
                guard fields.count == 3,
                      let added = Int(String(decoding: fields[0], as: UTF8.self)),
                      let removed = Int(String(decoding: fields[1], as: UTF8.self)) else { continue }
                additions += added
                deletions += removed
            }
        }
    }

    static func totals(in files: Files, scope: Scope) throws -> Totals {
        let args = ["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "--no-renames"]
        var totals = Totals()
        totals.include(try git(args + scope.arguments + ["--"], in: files.root))
        for path in files.untracked {
            try Task.checkCancellation()
            guard try isPreviewable(path, in: files) else { continue }
            let data = try git(args + newFileComparison(path), in: files.root, allowDifferences: true)
            // No-index compares two paths; Git writes their names after the stats record.
            totals.include(data.prefix { $0 != 0 })
        }
        return totals
    }

    static func patch(in files: Files, path: String, scope: Scope) throws -> [Row] {
        let args = ["diff", "--patch", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=3",
                    "--output-indicator-new=+", "--output-indicator-old=-", "--output-indicator-context= "]
        let isNew = files.untracked.contains(path)
        if isNew, try !isPreviewable(path, in: files) { return [] }
        let comparison = isNew ? newFileComparison(path) : scope.arguments + ["--", path]
        let data = try git(args + comparison, in: files.root, allowDifferences: isNew)
        return parse(String(decoding: data, as: UTF8.self))
    }

    private static func newFileComparison(_ path: String) -> [String] {
        ["--no-index", "--", "/dev/null", "./" + path]
    }

    private static func isPreviewable(_ path: String, in files: Files) throws -> Bool {
        let url = URL(fileURLWithPath: files.root).appendingPathComponent(path)
        let type = try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        return type == .typeRegular || type == .typeSymbolicLink
    }

    static func parse(_ patch: String) -> [Row] {
        var rows: [Row] = []
        var removed: [Line] = [], added: [Line] = []
        var old = 0, new = 0
        var inHunk = false, startsHunk = false

        func append(_ row: Row) {
            var row = row
            row.startsHunk = startsHunk
            rows.append(row)
            startsHunk = false
        }

        func flush() {
            for i in 0..<max(removed.count, added.count) {
                append(Row(old: i < removed.count ? removed[i] : nil,
                           new: i < added.count ? added[i] : nil, changed: true))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }

        // split on bytes so CRLF source lines still count as separate patch lines.
        for bytes in patch.utf8.split(separator: 10, omittingEmptySubsequences: false) {
            let line = String(decoding: bytes.last == 13 ? bytes.dropLast() : bytes[...], as: UTF8.self)
            if line.hasPrefix("@@ ") {
                flush()
                let fields = line.split(separator: " ")
                guard fields.count >= 4,
                      let left = Int(fields[1].dropFirst().prefix(while: { $0.isNumber })),
                      let right = Int(fields[2].dropFirst().prefix(while: { $0.isNumber })) else { inHunk = false; continue }
                old = left; new = right
                inHunk = true; startsHunk = true
                continue
            }
            if line.hasPrefix("diff --git ") { flush(); inHunk = false }
            guard inHunk else { continue }
            let content = String(line.dropFirst())
            switch line.first {
            case "-": removed.append(Line(number: old, text: content)); old += 1
            case "+": added.append(Line(number: new, text: content)); new += 1
            case " ":
                flush()
                append(Row(old: Line(number: old, text: content), new: Line(number: new, text: content)))
                old += 1; new += 1
            default: break // includes the missing-final-newline marker
            }
        }
        flush()
        return rows
    }

    private static func git(_ args: [String], in directory: String, allowDifferences: Bool = false) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        task.arguments = ["--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                          "-c", "diff.suppressBlankEmpty=false"] + args
        task.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        defer { try? output.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
            data.append(chunk)
            if data.count > 4_000_000 {
                if task.isRunning { task.terminate() }
                throw Failure(message: "this diff is too large to preview. use git diff in the terminal.")
            }
        }
        task.waitUntilExit()
        guard task.terminationReason == .exit,
              task.terminationStatus == 0 || (allowDifferences && task.terminationStatus == 1) else {
            throw Failure(message: args.first == "rev-parse" ? "could not open a git repository here." : "git could not read these changes.")
        }
        return data
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
