import SwiftUI

struct PaneAdjustment: Equatable {
    private let event = UUID()
    let divider: UUID?
    let points: CGFloat
}

// Rectangles are in AppKit window coordinates, with y increasing upward.
enum PaneDirection: String, CaseIterable {
    case left, right, up, down

    var vertical: Bool { self == .up || self == .down }
    var resizePoints: CGFloat { self == .left || self == .up ? -10 : 10 }

    func neighbor(from id: UUID, in frames: [(UUID, CGRect)]) -> UUID? {
        guard let origin = frames.first(where: { $0.0 == id })?.1 else { return nil }
        let positive = self == .up || self == .right
        return frames.compactMap { candidate, rect -> (UUID, (Bool, CGFloat, CGFloat))? in
            guard candidate != id, !rect.isEmpty else { return nil }
            let delta = vertical ? rect.midY - origin.midY : rect.midX - origin.midX
            guard positive ? delta > 0 : delta < 0 else { return nil }
            let gap = switch self {
            case .left: origin.minX - rect.maxX
            case .right: rect.minX - origin.maxX
            case .up: rect.minY - origin.maxY
            case .down: origin.minY - rect.maxY
            }
            guard gap >= -0.5 else { return nil }
            let overlap = vertical
                ? min(rect.maxX, origin.maxX) - max(rect.minX, origin.minX)
                : min(rect.maxY, origin.maxY) - max(rect.minY, origin.minY)
            let cross = vertical ? abs(rect.midX - origin.midX) : abs(rect.midY - origin.midY)
            return (candidate, (overlap <= 0, max(0, gap), cross))
        }.min { a, b in
            if a.1.0 != b.1.0 { return !a.1.0 }
            if a.1.1 != b.1.1 { return a.1.1 < b.1.1 }
            return a.1.2 < b.1.2
        }?.0
    }
}
