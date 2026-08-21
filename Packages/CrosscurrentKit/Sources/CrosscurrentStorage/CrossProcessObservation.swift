@preconcurrency import CoreFoundation
import Foundation

private func crosscurrentDarwinChangeName() -> CFString {
    "com.chonghanqin.crosscurrent.database.changed" as CFString
}

private func crosscurrentDarwinCallback(
    _: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    _: CFNotificationName?,
    _: UnsafeRawPointer?,
    _: CFDictionary?
) {
    guard let observer else { return }
    let hub = Unmanaged<CrossProcessObservationHub>.fromOpaque(observer).takeUnretainedValue()
    hub.receiveWakeHint()
}

public final class CrossProcessObservationHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var isStarted = false

    public init() {}

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            crosscurrentDarwinCallback,
            crosscurrentDarwinChangeName(),
            nil,
            .deliverImmediately
        )
    }

    public func wakeHints() -> AsyncStream<Void> {
        start()
        let id = UUID()
        return AsyncStream { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations[id] = nil }
            }
        }
    }

    public func postWakeHint() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(crosscurrentDarwinChangeName()),
            nil,
            nil,
            true
        )
    }

    fileprivate func receiveWakeHint() {
        let active = lock.withLock { Array(continuations.values) }
        active.forEach { $0.yield() }
    }

    deinit {
        if isStarted {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(crosscurrentDarwinChangeName()),
                nil
            )
        }
        continuations.values.forEach { $0.finish() }
    }
}
