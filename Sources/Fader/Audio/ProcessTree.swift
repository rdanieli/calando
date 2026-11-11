import Darwin
import Foundation

enum ProcessTree {
    private typealias ResponsiblePIDFunction = @convention(c) (pid_t) -> pid_t

    private static let responsiblePIDFunction: ResponsiblePIDFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsiblePIDFunction.self)
    }()

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&name, UInt32(name.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let function = responsiblePIDFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }
}
