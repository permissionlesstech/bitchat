//
// MemoryUtil.swift
// bitchat
// Lightweight helpers to snapshot app memory usage for diagnostics.
//

import Foundation
import Darwin

enum MemoryUtil {
    /// Returns resident memory size (RSS) in bytes for the current process, or nil on failure.
    static func residentSizeBytes() -> UInt64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return UInt64(info.resident_size)
    }

    /// Returns resident memory size in megabytes with 1 decimal precision, or nil on failure.
    static func residentSizeMB() -> Double? {
        guard let bytes = residentSizeBytes() else { return nil }
        return (Double(bytes) / (1024.0 * 1024.0)).rounded(toPlaces: 1)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

