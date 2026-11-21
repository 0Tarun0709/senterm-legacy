import Foundation

@main
struct ProjectsTests {
    static func main() throws {
        var list = ProjectList()
        let first = list.addProject(path: "/tmp/example/../project")
        assert(first == list.addProject(path: "/tmp/project"))
        assert(list.projects.count == 1)
        assert(list.projects[0].terminals.map(\.name) == ["terminal"])
        let terminal = list.projects[0].terminals[0].id
        list.projects[0].terminals.append(TerminalItem(name: "agent"))
        list.moveTerminal(id: terminal, projectID: first, by: 1)
        assert(list.projects[0].terminals.map(\.name) == ["agent", "terminal"])
        list.moveTerminal(id: terminal, projectID: first, by: 100)
        assert(list.projects[0].terminals[1].id == terminal)
        let second = list.addProject(path: "/tmp/another-project")
        for item in list.projects[1].terminals {
            _ = list.removeTerminal(id: item.id, projectID: second)
        }
        assert(list.projects[1].terminals.isEmpty)
        list.moveProject(id: second, by: -1)
        assert(list.firstTerminalID == list.projects[1].terminals.first?.id)
        list.moveProject(id: second, by: 1)
        assert(list.addProject(path: "/tmp/another-project") == second)
        assert(list.projects.count == 2)
        assert(list.projects[1].terminals.map(\.name) == ["terminal"])
        list.moveProject(id: second, by: -1)
        assert(list.projects[0].id == second)
        list.projects[1].label = "work"
        assert(list.projects[1].name == "work")
        let next = list.removeTerminal(id: terminal, projectID: first)
        assert(!list.projects[1].terminals.contains(where: { $0.id == terminal }))
        assert(next == list.projects[1].terminals.first?.id)
        let tabs = (0..<4).map { TerminalItem(name: "tab \($0)") }
        let tabProject = Project(path: "/tmp/tabs", terminals: tabs)
        var selection = ProjectList(projects: [tabProject])
        assert(selection.removeTerminal(id: tabs[1].id, projectID: tabProject.id) == tabs[2].id)
        assert(selection.removeTerminal(id: tabs[3].id, projectID: tabProject.id) == tabs[2].id)
        assert(selection.removeTerminal(id: tabs[3].id, projectID: tabProject.id) == nil)
        let legacy = try JSONDecoder().decode(TerminalItem.self, from: Data("""
        {"id":"2C08D4B0-C2EA-4E1A-AE20-D597AC6F7E08","name":"server"}
        """.utf8))
        assert(legacy.panes.ids == [legacy.id])
        let middle = UUID(), right = UUID()
        let layout = legacy.panes.splitting(legacy.id, with: middle, vertical: false)
            .splitting(middle, with: right, vertical: true)
        assert(layout.ids == [legacy.id, middle, right])
        assert(layout.removing(legacy.id) == .split(vertical: true, first: .shell(middle), second: .shell(right)))
        assert(PaneLayout.shell(right).removing(right) == nil)
        list.projects[1].terminals[0].layout = list.projects[1].terminals[0].panes
            .splitting(list.projects[1].terminals[0].id, with: right, vertical: false)

        let processes = """
         101 101 201 1 S -/bin/zsh -/bin/zsh
         201 201 201 101 S node node /opt/mytools/node_modules/@earendil-works/pi-coding-agent/dist/cli.js
         202 202 201 1 S /usr/local/bin/claude claude
         102 102 102 1 S -/bin/zsh -/bin/zsh
         301 301 102 102 S /usr/local/bin/codex codex
         103 103 401 1 S -/bin/zsh -/bin/zsh
         401 401 401 103 S /usr/local/bin/codex codex
         104 104 501 1 S -/bin/zsh -/bin/zsh
         501 501 501 104 S node node server.js claude
         105 105 601 1 S -/bin/zsh -/bin/zsh
         601 601 601 105 S pi pi
         106 106 701 1 S -/bin/zsh -/bin/zsh
         701 701 701 106 S /bin/zsh zsh wrapper
         702 701 701 701 S /usr/local/bin/openclaw openclaw tui
         703 701 701 701 Z /bin/sleep sleep
         704 704 -1 701 S /bin/sleep sleep 60
        """
        let shells: Set<Int32> = [101, 102, 103, 104, 105, 106]
        let overview = AgentProcesses.detect(in: processes, shells: shells)
        assert(overview.badges == [101: "pi", 103: "codex", 105: "pi", 106: "openclaw"])
        assert(overview.jobs.isEmpty)
        let detail = AgentProcesses.detect(in: processes, shells: shells, includeJobs: true)
        assert(detail.badges == overview.badges)
        assert(detail.jobs.mapValues { $0.map(\.id) } ==
            [101: [201], 102: [301], 103: [401], 104: [501], 105: [601], 106: [701, 702, 704]])
        assert(AgentProcesses.processTree(root: 701, jobs: detail.jobs[106] ?? []) == [701, 702, 704])
        assert(AgentProcesses.processTree(root: 702, jobs: detail.jobs[106] ?? []) == [702])
        let usage = AgentProcesses.parseUsage("  2.5  2048  01:23\n")
        assert(usage?.cpu == 2.5 && usage?.residentKiB == 2048 && usage?.elapsed == "01:23")
        assert(AgentProcesses.parseUsage("") == nil)
        assert(detail.jobs[104]?.first?.name == "node")
        assert(detail.jobs[106]?.first(where: { $0.id == 702 })?.badge == "openclaw")
        let idle = AgentProcesses.detect(in: "101 101 101 1 S -/bin/zsh -/bin/zsh", shells: [101], includeJobs: true)
        assert(idle.badges.isEmpty && idle.jobs.isEmpty)

        let jobs = """
         101 101 201 1 S -/bin/zsh -/bin/zsh
         201 201 201 101 S node node /usr/local/bin/pnpm dev
         102 102 301 1 S -/bin/zsh -/bin/zsh
         301 301 301 102 S /opt/bin/uv uv run app
         302 301 301 301 S /opt/bin/claude claude
         103 103 401 1 S -/bin/zsh -/bin/zsh
         401 401 401 103 S node node app.js
         104 104 104 1 S -/bin/zsh -/bin/zsh
         501 501 104 104 S node node app.js
         105 105 601 1 S -/bin/zsh -/bin/zsh
         601 601 601 105 S /opt/bin/bun bun run dev
         106 106 701 1 S -/bin/zsh -/bin/zsh
         701 701 701 106 S /opt/bin/ngrok ngrok http 3000
         107 107 801 1 S -/bin/zsh -/bin/zsh
         801 801 801 107 S /usr/local/go/bin/go go run .
         802 801 801 801 S /tmp/go-build123/b001/exe/app app
        """
        let snapshot = AgentProcesses.detect(in: jobs, shells: [101, 102, 103, 104, 105, 106, 107], includeJobs: true) { pids in
            assert(pids == [401])
            return [401]
        }
        assert(snapshot.jobs[103]?.first?.badge == "server")
        assert(snapshot.badges == [101: "pnpm", 102: "claude code", 103: "server", 105: "bun", 106: "ngrok", 107: "go"])
        assert(AgentProcesses.isAgent("claude code") && !AgentProcesses.isAgent("pnpm") && !AgentProcesses.isAgent("server"))

        var activity = ActivityRecords()
        assert(activity.apply("state=working:app=builder"))
        assert(activity.apply("state=blocked:id=build/test:kind=permission:progress=45:msg=aGVsbG8"))
        assert(activity.records.last?.message == "hello")
        assert(activity.records.last?.progress == 45)
        assert(activity.app(for: activity.records[1]) == "builder")
        assert(!activity.apply("state=clear:id=bad id"))
        assert(!activity.apply("state=clear:id="))
        assert(!activity.apply("state=done:msg=Cg=="))
        assert(!activity.apply("state=done:title=a"))
        assert(!activity.apply("state=done:msg=" + String(repeating: "a", count: 4096)))
        assert(activity.records.count == 2)
        assert(activity.apply("state=clear:id=build"))
        assert(activity.records.map(\.id) == [""])
        for index in 0..<65 { assert(activity.apply("state=done:id=task\(index)")) }
        assert(activity.records.count == 64 && activity.records.first?.id == "task1")
        assert(activity.apply("state=clear") && activity.records.isEmpty)

        let saved = try JSONEncoder().encode(list)
        let restored = try JSONDecoder().decode(ProjectList.self, from: saved)
        assert(restored == list)
        print("project tests passed")
    }
}
