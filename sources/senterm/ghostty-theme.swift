import Foundation

struct GhosttyTheme: Codable, Equatable {
    let name: String
    private(set) var colors: [String: UInt32] = [:]
    private(set) var palette: [Int: UInt32] = [:]

    init?(name: String, text: String) {
        self.name = name
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2 else { continue }
            if fields[0] == "palette" {
                let entry = fields[1].split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if entry.count == 2, let index = Int(entry[0]), (0..<16).contains(index), let rgb = Self.rgb(entry[1]) {
                    palette[index] = rgb
                }
            } else if ["foreground", "background", "cursor-color", "cursor-text", "selection-background", "selection-foreground"].contains(fields[0]), let rgb = Self.rgb(fields[1]) {
                colors[fields[0]] = rgb
            }
        }
        guard !colors.isEmpty || !palette.isEmpty else { return nil }
    }

    private static func rgb(_ string: String) -> UInt32? {
        let value = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard value.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return UInt32(value, radix: 16)
    }
}
