import Foundation

struct TerminalItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var layout: PaneLayout? = nil

    var panes: PaneLayout { layout ?? .shell(id) }
}

indirect enum PaneLayout: Codable, Equatable {
    case shell(UUID)
    case split(vertical: Bool, first: PaneLayout, second: PaneLayout)

    var ids: [UUID] {
        switch self {
        case .shell(let id): return [id]
        case .split(_, let first, let second): return first.ids + second.ids
        }
    }

    func splitting(_ id: UUID, with newID: UUID, vertical: Bool) -> Self {
        switch self {
        case .shell(let current):
            return id == current ? .split(vertical: vertical, first: self, second: .shell(newID)) : self
        case .split(let axis, let first, let second):
            return .split(vertical: axis, first: first.splitting(id, with: newID, vertical: vertical),
                          second: second.splitting(id, with: newID, vertical: vertical))
        }
    }

    var firstID: UUID {
        switch self {
        case .shell(let id): id
        case .split(_, let first, _): first.firstID
        }
    }

    func weight(vertical: Bool) -> Int {
        guard case .split(let axis, let first, let second) = self, axis == vertical else { return 1 }
        return first.weight(vertical: vertical) + second.weight(vertical: vertical)
    }

    func divider(for id: UUID, vertical: Bool) -> UUID? {
        guard case .split(let axis, let first, let second) = self else { return nil }
        let child: PaneLayout
        if first.ids.contains(id) { child = first }
        else if second.ids.contains(id) { child = second }
        else { return nil }
        return child.divider(for: id, vertical: vertical) ?? (axis == vertical ? second.firstID : nil)
    }

    func removing(_ id: UUID) -> Self? {
        switch self {
        case .shell(let current): return current == id ? nil : self
        case .split(let axis, let first, let second):
            let left = first.removing(id), right = second.removing(id)
            if let left, let right { return .split(vertical: axis, first: left, second: right) }
            return left ?? right
        }
    }
}

struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String
    var terminals: [TerminalItem] = []
    var label: String? = nil

    var name: String { label ?? URL(fileURLWithPath: path).lastPathComponent }
}

struct ProjectList: Codable, Equatable {
    var projects: [Project] = []

    var firstTerminalID: UUID? {
        projects.lazy.compactMap { $0.terminals.first?.id }.first
    }

    mutating func removeTerminal(id: UUID, projectID: UUID) -> UUID? {
        guard let p = projects.firstIndex(where: { $0.id == projectID }),
              let t = projects[p].terminals.firstIndex(where: { $0.id == id }) else { return nil }
        projects[p].terminals.remove(at: t)
        let tabs = projects[p].terminals
        return tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
    }

    mutating func moveProject(id: UUID, by offset: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }), projects.indices.contains(from + offset) else { return }
        projects.swapAt(from, from + offset)
    }

    mutating func moveTerminal(id: UUID, projectID: UUID, by offset: Int) {
        guard let p = projects.firstIndex(where: { $0.id == projectID }),
              let from = projects[p].terminals.firstIndex(where: { $0.id == id }),
              projects[p].terminals.indices.contains(from + offset) else { return }
        projects[p].terminals.swapAt(from, from + offset)
    }

    mutating func addProject(path: String) -> UUID {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        if let index = projects.firstIndex(where: { $0.path == path }) {
            if projects[index].terminals.isEmpty {
                projects[index].terminals = [TerminalItem(name: "terminal")]
            }
            return projects[index].id
        }
        let project = Project(path: path, terminals: [TerminalItem(name: "terminal")])
        projects.append(project)
        return project.id
    }
}
