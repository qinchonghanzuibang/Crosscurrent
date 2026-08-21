import Foundation
import OSLog

public enum CrosscurrentLog {
    public static let app = Logger(subsystem: "com.chonghanqin.crosscurrent", category: "app")
    public static let storage = Logger(subsystem: "com.chonghanqin.crosscurrent", category: "storage")
    public static let connector = Logger(subsystem: "com.chonghanqin.crosscurrent", category: "connector")
    public static let browser = Logger(subsystem: "com.chonghanqin.crosscurrent", category: "browser")
    public static let intelligence = Logger(subsystem: "com.chonghanqin.crosscurrent", category: "intelligence")
}

public struct TraceContext: Codable, Hashable, Sendable {
    public var traceID: UUID
    public var parentID: UUID?

    public init(traceID: UUID = UUID(), parentID: UUID? = nil) {
        self.traceID = traceID
        self.parentID = parentID
    }
}
