import os

enum Log {
    static let app = Logger(subsystem: "com.michaelrigart.hulder", category: "app")
    static let ui = Logger(subsystem: "com.michaelrigart.hulder", category: "ui")
}
