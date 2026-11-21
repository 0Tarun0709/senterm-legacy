import Foundation

@main
struct GitChangesTests {
    static func main() throws {
        func checkSpans(_ old: String, _ new: String, _ removed: String, _ added: String) {
            let spans = GitChanges.changedSpans(old: old, new: new)
            precondition(old[spans.old] == removed && new[spans.new] == added)
        }
        checkSpans("let 🌱 = old()", "let 🌱 = new()", "old", "new")
        checkSpans("abc", "abXYZc", "", "XYZ")
        checkSpans("same", "same", "", "")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.arguments = ["-c", "user.name=senterm test", "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgsign=false"] + arguments
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }

        let name = "file [1].txt"
        let file = root.appendingPathComponent(name)
        try git("init", "-q", "-b", "main")
        try "context\r\nbefore\r\n".write(to: file, atomically: true, encoding: .utf8)
        try git("add", "--", name)
        try git("commit", "-qm", "initial")
        try "context\r\nstaged\r\n".write(to: file, atomically: true, encoding: .utf8)
        try git("add", "--", name)
        try "context\r\nworking\r\nextra\r\n".write(to: file, atomically: true, encoding: .utf8)
        let untracked = "-new.txt"
        try "new\n".write(to: root.appendingPathComponent(untracked), atomically: true, encoding: .utf8)

        let staged = try GitChanges.files(in: root.path, scope: .staged)
        let working = try GitChanges.files(in: root.path, scope: .unstaged)
        precondition(staged.revision == "main" && working.revision == "main")
        precondition(staged.paths == [name] && staged.untracked.isEmpty)
        precondition(working.paths == [untracked, name] && working.untracked == [untracked])
        precondition(staged.status == [name: "M"] && working.status == [name: "M", untracked: "?"])
        let left = try GitChanges.patch(in: staged, path: name, scope: .staged)
        let right = try GitChanges.patch(in: working, path: name, scope: .unstaged)
        let added = try GitChanges.patch(in: working, path: untracked, scope: .unstaged)
        precondition(left.count == 2 && left[0].startsHunk && !left[0].changed && left[1].changed)
        precondition(left[1].old == .init(number: 2, text: "before") && left[1].new?.text == "staged")
        precondition(right.count == 3 && right[1].old?.text == "staged" && right[1].new?.text == "working")
        precondition(right[2].old == nil && right[2].new == .init(number: 3, text: "extra"))
        precondition(added.count == 1 && added[0].old == nil && added[0].new?.text == "new")
        let stagedTotals = try GitChanges.totals(in: staged, scope: .staged)
        precondition(stagedTotals.additions == 1 && stagedTotals.deletions == 1)

        // Include text across files, but don't count binary changes as lines.
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary\tfile"))
        let files = try GitChanges.files(in: root.path, scope: .unstaged)
        let workingTotals = try GitChanges.totals(in: files, scope: .unstaged)
        precondition(files.paths.count == 3)
        precondition(workingTotals.additions == 3 && workingTotals.deletions == 1)
        let worktree = root.appendingPathComponent("review-worktree")
        try git("worktree", "add", "-qb", "review/feature", worktree.path)
        let review = try GitChanges.files(in: worktree.path, scope: .unstaged)
        precondition((review.root as NSString).lastPathComponent == "review-worktree")
        precondition(review.revision == "review/feature")

        let notes = DiffReview(gitDirectory: working.gitDirectory)
        let linkedNotes = DiffReview(gitDirectory: review.gitDirectory)
        precondition(notes.file != linkedNotes.file)
        let old = DiffReview.Anchor(revision: working.revision, scope: .unstaged, path: name,
                                    side: .old, line: 2, text: "staged")
        let new = DiffReview.Anchor(revision: working.revision, scope: .unstaged, path: name,
                                    side: .new, line: 2, text: "working")
        let emptyNotes = try notes.read()
        precondition(emptyNotes.isEmpty)
        try notes.save(" refactor this\nkeep the existing behavior ", at: old)
        try notes.save("rename this", at: new)
        let saved = try DiffReview(gitDirectory: working.gitDirectory).read()
        precondition(saved.map(\.anchor) == [old, new])
        precondition(saved.first?.note == "refactor this\nkeep the existing behavior")
        let otherWorktree = try linkedNotes.read()
        precondition(otherWorktree.isEmpty)
        let unrelated = DiffReview.Comment(
            anchor: .init(revision: "other", scope: .staged, path: name, side: .old, line: 1, text: "other"),
            note: "other branch comment")
        try notes.save(unrelated.note, at: unrelated.anchor)
        let listed = try JSONDecoder().decode([DiffReview.Comment].self, from: DiffReview.list(in: root.path))
        let linkedList = try JSONDecoder().decode([DiffReview.Comment].self, from: DiffReview.list(in: worktree.path))
        precondition(listed.map(\.anchor) == [old, new] && linkedList.isEmpty)
        try notes.save(nil, at: unrelated.anchor)
        let prompt = DiffReview.agentPrompt(root: working.root, revision: working.revision, comments: saved + [unrelated])
        precondition(prompt.contains(working.root.debugDescription) && prompt.contains("\"main\""))
        precondition(prompt.contains(name.debugDescription + ":2 (unstaged, old side)"))
        precondition(prompt.contains("original line: \"staged\"") && prompt.contains("rename this"))
        precondition(prompt.contains("refactor this\\nkeep the existing behavior"))
        precondition(!prompt.contains(notes.file.path) && !prompt.contains(unrelated.note))
        try notes.save("simplify this", at: old)
        try notes.save(nil, at: new)
        let edited = try notes.read()
        precondition(edited.count == 1 && edited[0].anchor == old && edited[0].note == "simplify this")
        let unchangedFiles = try GitChanges.files(in: root.path, scope: .unstaged)
        precondition(unchangedFiles.paths == files.paths)
        try git("switch", "--detach", "-q")
        let detached = try GitChanges.files(in: root.path, scope: .unstaged)
        precondition(detached.revision?.hasPrefix("detached @ ") == true)
        print("git changes tests passed")
    }
}
