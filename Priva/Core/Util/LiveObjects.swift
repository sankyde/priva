import Foundation

/// How many of each long-lived object exist right now (DEBUG builds; a no-op in Release). Anything still counted
/// after Priva locks is memory, and possibly keys, that should have gone. Read by the leak tests and by
/// Settings › Diagnostics, so the device journeys can check it on a real iPhone.
nonisolated enum LiveObjects {
    #if DEBUG
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func born(_ type: String) { lock.withLock { counts[type, default: 0] += 1 } }
    static func died(_ type: String) { lock.withLock { counts[type, default: 0] -= 1 } }
    static func count(_ type: String) -> Int { lock.withLock { counts[type] ?? 0 } }
    /// Every type with at least one live object.
    static var snapshot: [String: Int] { lock.withLock { counts.filter { $0.value != 0 } } }

    /// This app's memory footprint as iOS counts it for the memory limit (phys_footprint), in MB.
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
    #else
    @inline(__always) static func born(_ type: String) {}
    @inline(__always) static func died(_ type: String) {}
    #endif
}
