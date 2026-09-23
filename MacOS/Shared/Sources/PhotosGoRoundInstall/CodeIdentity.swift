import Darwin
import Foundation

/// Facts that say whether a running process is still running what is on disk.
///
/// **Not the code signature, though that was the first idea.** Measured
/// 2026-09-21: `SecCodeCopyGuestWithAttributes` for a pid, with or without
/// `kSecCSDynamicInformation`, reported the hash of the file *now* at the
/// process's path, not of the code it was running — replace a running binary
/// and it answers with the replacement's. The kernel's own record (`csops`)
/// does not move, but it is not public API. So `AgentInstall` compares when
/// the binary last changed with when the process started.
public enum CodeIdentity {

    /// When a file's inode last changed — **`ctime`, not the modification date.**
    ///
    /// Copying or moving a file into place sets it to that moment, and nothing
    /// that copies can preserve it; a modification date survives a Finder copy
    /// and a `cp -p`. Measured 2026-09-21: a binary with a modification date
    /// of 2020 moved over a running one read as changed after the process
    /// started, and so did `ditto` over it in place.
    public static func changedAt(_ file: URL) -> Date? {
        var status = stat()
        guard stat(file.path(percentEncoded: false), &status) == 0 else { return nil }
        let time = status.st_ctimespec
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
    }

    /// When a process started, from the kernel.
    public static func startedAt(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let time = info.kp_proc.p_un.__p_starttime
        guard time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1e6)
    }
}
