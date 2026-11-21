import SwiftUI

struct ProcessDetailsView: View {
    let pid: Int32
    let pids: Set<Int32>
    @State private var details: AgentProcesses.Details?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let details {
                Text("cpu: \(details.cpu.formatted(.number.precision(.fractionLength(1))))%")
                Text("memory (rss): \(ByteCountFormatter.string(fromByteCount: details.residentKiB * 1024, countStyle: .memory))")
                Text("elapsed: \(details.elapsed)")
                Text("tcp listening ports").fontWeight(.medium).padding(.top, 3)
                if details.listeners.isEmpty {
                    Text("none detected")
                } else {
                    ForEach(details.listeners, id: \.self) { address in
                        Text(verbatim: address).textSelection(.enabled)
                    }
                }
            } else {
                Text(loaded ? "process details unavailable" : "loading process details…")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .task(id: pids) {
            let root = pid
            let tree = pids
            while !Task.isCancelled {
                let sample = await Task.detached(priority: .utility) {
                    AgentProcesses.details(pid: root, including: tree)
                }.value
                guard !Task.isCancelled else { return }
                details = sample
                loaded = true
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
