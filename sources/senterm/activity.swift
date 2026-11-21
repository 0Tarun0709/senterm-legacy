import Foundation

struct ActivityRecords {
    struct Record: Identifiable {
        let id: String
        let state: String
        let title: String?
        let message: String?
        let app: String?
        let progress: Int?
        let kind: String?
    }

    private(set) var records: [Record] = []

    func app(for record: Record) -> String? {
        if let app = record.app { return app }
        var id = record.id
        while !id.isEmpty {
            id = id.lastIndex(of: "/").map { String(id[..<$0]) } ?? ""
            if let app = records.first(where: { $0.id == id })?.app { return app }
        }
        return nil
    }

    mutating func apply(_ payload: String) -> Bool {
        guard payload.utf8.count <= 4087 else { return false }
        var fields: [String: String] = [:]
        for pair in payload.split(separator: ":") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard key.utf8.count <= 16 else { return false }
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) }) else { continue }
            guard value.utf8.allSatisfy({ Self.identifierByte($0) || [44, 47, 61].contains($0) }) else {
                if key == "id" { return false }
                continue
            }
            switch key {
            case "msg", "title":
                guard Self.decode(value, limit: key == "msg" ? 2048 : 192) != nil else { return false }
            case "id":
                let segments = value.split(separator: "/", omittingEmptySubsequences: false)
                guard value.utf8.count <= 128, segments.count <= 8, segments.allSatisfy({ Self.identifier(String($0)) }) else { return false }
            case "app":
                guard value.utf8.count <= 32 else { return false }
            case "state", "progress", "kind": break
            default: continue
            }
            fields[key] = value
        }
        let id = fields["id"] ?? ""
        guard let state = fields["state"] else { return false }
        if state == "clear" {
            records.removeAll { id.isEmpty || $0.id == id || $0.id.hasPrefix(id + "/") }
            return true
        }
        guard ["idle", "working", "done", "blocked", "error"].contains(state) else { return false }
        let app = fields["app"].flatMap { Self.identifier($0) ? $0 : nil }
        let progress = ["working", "blocked"].contains(state) ? fields["progress"].flatMap { Int($0) }.flatMap { (0...100).contains($0) ? $0 : nil } : nil
        let kind = state == "blocked" ? fields["kind"].flatMap { ["permission", "question", "auth"].contains($0) ? $0 : nil } : nil
        records.removeAll { $0.id == id }
        if records.count == 64 { records.removeFirst() }
        records.append(Record(id: id, state: state, title: fields["title"].flatMap { Self.decode($0, limit: 192) },
                              message: fields["msg"].flatMap { Self.decode($0, limit: 2048) }, app: app, progress: progress, kind: kind))
        return true
    }

    private static func identifierByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [43, 45, 46, 95].contains(byte)
    }

    private static func identifier(_ value: String) -> Bool {
        (1...32).contains(value.utf8.count) && value.utf8.allSatisfy(identifierByte)
    }

    private static func decode(_ value: String, limit: Int) -> String? {
        guard value.utf8.count <= ((limit + 2) / 3) * 4 else { return nil }
        let padding = (4 - value.utf8.count % 4) % 4
        guard let data = Data(base64Encoded: value + String(repeating: "=", count: padding)), data.count <= limit,
              let text = String(data: data, encoding: .utf8),
              text.unicodeScalars.allSatisfy({ !($0.value < 32 || (127...159).contains($0.value)) }) else { return nil }
        return text
    }
}
