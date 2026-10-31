import os

public enum PlatformLog {
    static let probe = Logger(subsystem: "com.michaelrigart.hulder", category: "probe")
    static let concealment = Logger(subsystem: "com.michaelrigart.hulder", category: "concealment")
    static let scan = Logger(subsystem: "com.michaelrigart.hulder", category: "scan")
    static let menus = Logger(subsystem: "com.michaelrigart.hulder", category: "menus")
    static let order = Logger(subsystem: "com.michaelrigart.hulder", category: "order")
}
