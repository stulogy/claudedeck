import Foundation

enum SystemMemory {
    static let physicalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
}
