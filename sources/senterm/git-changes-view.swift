import AppKit
import SwiftUI

struct GitChangesRequest: Codable, Hashable {
    let id: UUID
    let path: String
    let scope: GitChanges.Scope

    init(path: String, scope: GitChanges.Scope) {
        id = UUID()
        self.path = path
        self.scope = scope
    }
}

struct GitChangesView: View {
    let directory: String
    @State private var scope: GitChanges.Scope
    @State private var refresh = 0
    @State private var files: GitChanges.Files?
    @State private var loadedScope: GitChanges.Scope?
    @State private var loadedRefresh: Int?
    @State private var selection: String?
    @State private var rows: [GitChanges.Row] = []
    @State private var error: String?
    @State private var loading = true
    @State private var hunk: Int?
    @State private var comments: [DiffReview.Comment] = []
    @State private var reviewVisible = false
    @State private var commentAnchor: DiffReview.Anchor?
    @State private var hoveredComment: DiffReview.Anchor?
    @FocusState private var focusedComment: DiffReview.Anchor?
    @State private var commentDraft = ""
    @State private var reviewError: String?
    @State private var promptCopied = false

    let palette: WindowPalette
    private var editor: Color { palette.diffEditor }
    private var sidebar: Color { palette.diffSidebar }
    private var chrome: Color { palette.diffHeader }
    private var light: Bool { palette.scheme == .light }

    // Keep delta's red/green meaning in both appearances.
    private var removed: Color { light ? Color(rgb: 0xffe0e0) : Color(rgb: 0x3f0001) }
    private var added: Color { light ? Color(rgb: 0xd0ffd0) : Color(rgb: 0x002800) }
    private var removedEmphasis: Color { light ? Color(rgb: 0xffb8b8) : Color(rgb: 0x901011) }
    private var addedEmphasis: Color { light ? Color(rgb: 0xa0efa0) : Color(rgb: 0x006000) }

    init(directory: String, initialScope: GitChanges.Scope, palette: WindowPalette) {
        self.directory = directory
        self.palette = palette
        _scope = State(initialValue: initialScope)
    }

    private struct PatchRequest: Hashable {
        let path: String?
        let scope: GitChanges.Scope
        let refresh: Int
    }

    private var worktreeName: String { ((files?.root ?? directory) as NSString).lastPathComponent }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                fileSidebar.frame(minWidth: 200, idealWidth: 265, maxWidth: 370)
                detail.frame(minWidth: 530, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                Text(verbatim: worktreeName)
                    .lineLimit(1)
                    .help(files?.root ?? directory)
                if let revision = files?.revision {
                    Text(verbatim: revision).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let files, loadedScope == scope, loadedRefresh == refresh {
                    DiffTotalsView(files: files, scope: scope)
                        .id(PatchRequest(path: nil, scope: scope, refresh: refresh))
                }
                Button { openReview() } label: {
                    Label("review comments (\(revisionComments.count))", systemImage: "bubble.left")
                }
                .buttonStyle(.borderless)
                .disabled(files == nil || loadedScope != scope || loadedRefresh != refresh)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 23)
            .background(chrome)
        }
        .frame(minWidth: 760, minHeight: 470)
        .background(editor)
        .navigationTitle(files?.revision.map { "\(worktreeName) · \($0) — git changes" } ?? "\(worktreeName) — git changes")
        .task(id: PatchRequest(path: selection, scope: scope, refresh: refresh)) { await load() }
        .sheet(isPresented: $reviewVisible) { reviewSheet }
    }

    private var fileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("source control", systemImage: "arrow.triangle.branch")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("refresh changes").accessibilityLabel("refresh changes")
            }
            .padding(12)
            Picker("show", selection: $scope) {
                ForEach(GitChanges.Scope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12)
            HStack {
                Text("changes").fontWeight(.semibold)
                Spacer()
                Text("\(files?.paths.count ?? 0)").monospacedDigit()
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue.opacity(0.3), in: Capsule())
            }
            .font(.caption).padding(12)
            List(selection: $selection) {
                ForEach(files?.paths ?? [], id: \.self) { path in
                    let name = path as NSString
                    let status = files?.status[path] ?? ""
                    HStack(spacing: 6) {
                        Image(systemName: status == "?" || status == "A" ? "doc.badge.plus" : "doc.text")
                            .foregroundStyle(.blue)
                        Text(verbatim: name.lastPathComponent).lineLimit(1).layoutPriority(1)
                        if path.contains("/") {
                            Text(verbatim: name.deletingLastPathComponent)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Text(verbatim: status == "?" ? "U" : status)
                            .font(.caption.monospaced())
                            .foregroundStyle(status == "?" || status == "A" ? Color.green : status == "D" ? .red : .orange)
                    }
                    .font(.callout).tag(path).help(path)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
        }
        .background(sidebar)
    }

    private struct DiffTotalsView: View {
        let files: GitChanges.Files
        let scope: GitChanges.Scope
        @State private var totals: GitChanges.Totals?
        @State private var failed = false

        var body: some View {
            HStack(spacing: 8) {
                Text("\(files.paths.count) \(files.paths.count == 1 ? "file" : "files")")
                if let totals {
                    Text("+\(totals.additions)").foregroundStyle(.green)
                        .accessibilityLabel("\(totals.additions) lines added")
                    Text("−\(totals.deletions)").foregroundStyle(.red)
                        .accessibilityLabel("\(totals.deletions) lines removed")
                } else {
                    Text(failed ? "line totals unavailable" : "counting lines…")
                }
            }
            .monospacedDigit()
            .padding(.trailing, 8)
            .task {
                let worker = Task.detached(priority: .utility) {
                    try GitChanges.totals(in: files, scope: scope)
                }
                do {
                    let result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        worker.cancel()
                    }
                    if !Task.isCancelled { totals = result }
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if loading {
            ProgressView().controlSize(.small)
        } else if let error {
            Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
        } else if let selection {
            ScrollViewReader { proxy in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Label((selection as NSString).lastPathComponent, systemImage: "doc.text")
                            .font(.callout.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 33)
                            .background(editor)
                        Spacer(minLength: 4)
                        hunkButton(next: false, proxy: proxy)
                        hunkButton(next: true, proxy: proxy).padding(.trailing, 8)
                    }
                    .background(chrome)
                    HStack {
                        Text(verbatim: selection.components(separatedBy: "/").joined(separator: "  ›  "))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("side-by-side diff")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 25)
                    Divider()
                    HStack(spacing: 0) {
                        heading(scope == .staged ? "head" : "index")
                        Divider()
                        heading(scope == .staged ? "staged" : "working tree")
                    }
                    .frame(height: 28)
                    Divider()
                    if rows.isEmpty {
                        Text("no text changes to display").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(rows.indices, id: \.self) { index in
                                    let row = rows[index]
                                    diffRow(row, path: selection)
                                        .id(index)
                                }
                            }
                            .padding(.vertical, 4)
                            .textSelection(.enabled)
                        }
                    }
                }
            }
        } else {
            Text(files?.paths.isEmpty == false ? "select a file" : "no \(scope.rawValue) changes")
                .foregroundStyle(.secondary)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 10).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func diffRow(_ row: GitChanges.Row, path: String) -> some View {
        let spans = if row.changed, let old = row.old, let new = row.new {
            GitChanges.changedSpans(old: old.text, new: new.text)
        } else { nil as (old: Range<String.Index>, new: Range<String.Index>)? }

        return VStack(spacing: 0) {
            if row.startsHunk {
                let oldLocation = row.old.map { String($0.number) } ?? "–"
                let newLocation = row.new.map { String($0.number) } ?? "–"
                Text("@@ −\(oldLocation) +\(newLocation) @@")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.blue.opacity(0.8))
                    .padding(.horizontal, 12).frame(height: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(chrome)
            }
            HStack(alignment: .top, spacing: 0) {
                line(row.old, span: spans?.old, emphasis: removedEmphasis, marker: row.changed ? "−" : " ", path: path, side: .old)
                line(row.new, span: spans?.new, emphasis: addedEmphasis, marker: row.changed ? "+" : " ", path: path, side: .new)
            }
            .background {
                HStack(spacing: 0) {
                    cellBackground(missing: row.old == nil, color: row.changed ? removed : .clear)
                    Rectangle().fill(.quaternary).frame(width: 1)
                    cellBackground(missing: row.new == nil, color: row.changed ? added : .clear)
                }
            }
        }
    }

    @ViewBuilder private func cellBackground(missing: Bool, color: Color) -> some View {
        if missing {
            Canvas { context, size in
                var stripes = Path()
                for x in stride(from: -size.height, to: size.width, by: 6) {
                    stripes.move(to: CGPoint(x: x, y: size.height))
                    stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(stripes, with: .color(palette.ink.opacity(0.12)), lineWidth: 1)
            }
            .accessibilityHidden(true)
        } else {
            color
        }
    }

    private func line(_ line: GitChanges.Line?, span: Range<String.Index>?, emphasis: Color, marker: String,
                      path: String, side: DiffReview.Anchor.Side) -> some View {
        let anchor = line.flatMap { line in
            files.map { DiffReview.Anchor(revision: $0.revision, scope: scope, path: path,
                                          side: side, line: line.number, text: line.text) }
        }
        return HStack(alignment: .top, spacing: 6) {
            Group {
                if let anchor {
                    let hasNote = comments.contains { $0.anchor == anchor }
                    let visible = hasNote || hoveredComment == anchor || focusedComment == anchor
                    let label = "\(hasNote ? "edit" : "add") comment on \(side.rawValue) line \(anchor.line)"
                    Button { openReview(anchor) } label: {
                        Image(systemName: hasNote ? "bubble.left.fill" : "bubble.left")
                            .foregroundStyle(hasNote ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.borderless).help(label).accessibilityLabel(label)
                    .focused($focusedComment, equals: anchor)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                }
            }
            .frame(width: 18)
            Text(line.map { "\($0.number) \(marker)" } ?? "")
                .foregroundStyle(.secondary).frame(width: 43, alignment: .trailing)
            Text(code(line?.text ?? "", span: span, emphasis: emphasis))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.trailing, 8).padding(.vertical, 2)
        .frame(minHeight: 19)
        .contentShape(Rectangle())
        .onHover { hovering in
            guard let anchor else { return }
            if hovering { hoveredComment = anchor }
            else if hoveredComment == anchor { hoveredComment = nil }
        }
    }

    private var revisionComments: [DiffReview.Comment] {
        comments.filter { $0.anchor.revision == files?.revision }
    }

    private func openReview(_ anchor: DiffReview.Anchor? = nil) {
        guard let files else { return }
        reviewError = nil
        promptCopied = false
        do {
            comments = try DiffReview(gitDirectory: files.gitDirectory).read()
        } catch {
            reviewError = error.localizedDescription
        }
        editComment(anchor)
        reviewVisible = true
    }

    private func editComment(_ anchor: DiffReview.Anchor?) {
        commentAnchor = anchor
        commentDraft = comments.first { $0.anchor == anchor }?.note ?? ""
    }

    private func saveComment(_ note: String?, at anchor: DiffReview.Anchor) {
        guard let files else { return }
        do {
            comments = try DiffReview(gitDirectory: files.gitDirectory).save(note, at: anchor)
            reviewError = nil
            promptCopied = false
            editComment(nil)
        } catch {
            reviewError = error.localizedDescription
        }
    }

    private func commentLocation(_ anchor: DiffReview.Anchor) -> String {
        "\(anchor.path):\(anchor.line) · \(anchor.scope.rawValue) · \(anchor.side.rawValue)"
    }

    private var reviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(commentAnchor == nil ? "review comments" : "line comment").font(.headline)
            if let anchor = commentAnchor {
                Text(verbatim: commentLocation(anchor)).textSelection(.enabled)
                Text(verbatim: anchor.text).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                TextEditor(text: $commentDraft).accessibilityLabel("review comment")
                    .frame(minHeight: 110).border(.quaternary)
                HStack {
                    Button("back") { editComment(nil) }
                    if comments.contains(where: { $0.anchor == anchor }) {
                        Button("delete comment", role: .destructive) { saveComment(nil, at: anchor) }
                    }
                    Spacer()
                    Button("save comment") { saveComment(commentDraft, at: anchor) }
                        .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                if revisionComments.isEmpty {
                    Text("no comments for this revision").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(revisionComments) { comment in
                                VStack(alignment: .leading, spacing: 4) {
                                    Button { editComment(comment.anchor) } label: {
                                        Text(verbatim: commentLocation(comment.anchor)).multilineTextAlignment(.leading)
                                    }
                                    .buttonStyle(.link)
                                    Text(verbatim: comment.note).textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
                HStack {
                    Button(promptCopied ? "prompt copied" : "copy agent prompt") {
                        guard let files else { return }
                        let prompt = DiffReview.agentPrompt(root: files.root, revision: files.revision, comments: comments)
                        let clipboard = NSPasteboard.general
                        clipboard.clearContents()
                        promptCopied = clipboard.setString(prompt, forType: .string)
                    }
                    .disabled(revisionComments.isEmpty || reviewError != nil)
                    Spacer()
                    Button("done") { reviewVisible = false }.keyboardShortcut(.cancelAction)
                }
            }
            if let reviewError { Text(reviewError).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(16).frame(width: 530)
    }

    private func code(_ text: String, span: Range<String.Index>?, emphasis: Color) -> AttributedString {
        func run(_ value: Substring) -> AttributedString {
            AttributedString(value.replacingOccurrences(of: "\t", with: "    "))
        }
        guard let span, !span.isEmpty else { return run(text[...]) }
        var highlighted = run(text[span])
        highlighted.backgroundColor = emphasis
        return run(text[..<span.lowerBound]) + highlighted + run(text[span.upperBound...])
    }

    private func hunkButton(next: Bool, proxy: ScrollViewProxy) -> some View {
        let indices = rows.indices.filter { rows[$0].startsHunk }
        let target = next ? indices.first { $0 > (hunk ?? -1) } : indices.last { $0 < (hunk ?? 0) }
        let label = next ? "next change" : "previous change"
        return Button {
            if let target {
                hunk = target
                proxy.scrollTo(target, anchor: .top)
            }
        } label: {
            Image(systemName: next ? "arrow.down" : "arrow.up")
        }
        .buttonStyle(.borderless).frame(width: 27)
        .disabled(target == nil).help(label).accessibilityLabel(label)
    }

    private func load() async {
        let scope = scope, refresh = refresh, directory = directory
        loading = true
        error = nil
        rows = []
        hunk = nil
        do {
            if loadedScope != scope || loadedRefresh != refresh {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GitChanges.files(in: directory, scope: scope)
                }.value
                guard !Task.isCancelled else { return }
                files = result
                comments = (try? DiffReview(gitDirectory: result.gitDirectory).read()) ?? []
                loadedScope = scope
                loadedRefresh = refresh
                if selection.map(result.paths.contains) != true, selection != result.paths.first {
                    selection = result.paths.first
                    return // The new selection starts the patch task.
                }
            }
            if let files, let selection {
                let result = try await Task.detached(priority: .userInitiated) {
                    try GitChanges.patch(in: files, path: selection, scope: scope)
                }.value
                guard !Task.isCancelled else { return }
                rows = result
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            if loadedScope != scope || loadedRefresh != refresh { files = nil }
        }
        loading = false
    }
}
