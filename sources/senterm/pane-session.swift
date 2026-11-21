import Foundation
import Darwin

enum PaneSession {
    static func directory(pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            let path = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return path.hasPrefix("/") ? path : nil
        }
    }

    static func stopJobs(shell pid: pid_t) {
        guard pid > 1, getsid(pid) == pid, getsid(0) != pid else { return }
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var groups: [pid_t: pid_t] = [:]
        for member in pids.prefix(max(0, Int(count))) where member > 1 && getsid(member) == pid {
            let group = getpgid(member)
            if group > 1 { groups[group] = member }
        }
        // shortcut: signal ordinary jobs in this PTY session, not jobs that created a new session.
        for group in groups.keys.sorted(by: { ($0 == pid ? 1 : 0, $0) < ($1 == pid ? 1 : 0, $1) }) {
            guard let member = groups[group], getsid(member) == pid, getpgid(member) == group else { continue }
            if kill(-group, SIGTERM) == 0, getsid(member) == pid, getpgid(member) == group {
                kill(-group, SIGCONT)
            }
        }
    }
}
