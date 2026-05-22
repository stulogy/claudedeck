import Foundation
import Darwin

/// Reads RSS (resident set size) for a process by PID via the `proc_pidinfo`
/// syscall — no shell-out, no entitlements required for processes the user owns.
enum ProcessMemory {
    static func residentBytes(pid: pid_t) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard ret == size else { return nil }
        return info.pti_resident_size
    }

    /// RSS of the process AND any direct descendants. Useful because the shell
    /// we spawn `exec`s into `claude` — most of the time the PID we hold IS
    /// claude, but if anything ever does fork+exec we still capture the child.
    static func residentBytesIncludingChildren(pid: pid_t) -> UInt64? {
        var total = residentBytes(pid: pid) ?? 0
        for child in directChildren(of: pid) {
            total &+= residentBytes(pid: child) ?? 0
        }
        return total > 0 ? total : nil
    }

    private static func directChildren(of parent: pid_t) -> [pid_t] {
        // First call: get the buffer size needed.
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let count = Int(needed) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, needed)
        guard bytes > 0 else { return [] }
        let actual = Int(bytes) / MemoryLayout<pid_t>.size
        var children: [pid_t] = []
        for i in 0..<actual {
            let pid = pids[i]
            if pid == 0 { continue }
            var info = proc_bsdinfo()
            let sz = Int32(MemoryLayout<proc_bsdinfo>.size)
            let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sz)
            if r == sz, info.pbi_ppid == UInt32(parent) {
                children.append(pid)
            }
        }
        return children
    }
}
