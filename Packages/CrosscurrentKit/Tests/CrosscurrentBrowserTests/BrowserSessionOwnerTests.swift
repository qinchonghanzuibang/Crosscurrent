@testable import CrosscurrentBrowser
import Foundation
import Testing

@Test @MainActor func browserProfileOwnsTheCompleteAsyncSnapshotAndSkipsCancelledRequests() async throws {
    let gate = BrowserProfileOperationGate()
    let profile = UUID()
    let loaded = BrowserTestSignal()
    let releaseSnapshot = BrowserTestSignal()
    let queued = BrowserTestSignal()
    var operations: [String] = []
    let first = Task { @MainActor in
        try await gate.withOperation(profile) {
            operations.append("loaded first page")
            loaded.resume()
            await releaseSnapshot.wait()
            operations.append("extracted first page")
        }
    }
    await loaded.wait()
    let cancelled = Task { @MainActor in
        queued.resume()
        try await gate.withOperation(profile) { operations.append("cancelled navigation") }
    }
    await queued.wait()
    cancelled.cancel()
    try await gate.withOperation(UUID()) { operations.append("other profile") }
    releaseSnapshot.resume()
    try await first.value
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await gate.withOperation(profile) { operations.append("next page") }
    #expect(operations == ["loaded first page", "other profile", "extracted first page", "next page"])
}

@MainActor private final class BrowserTestSignal {
    private var signalled = false
    private var waiting: CheckedContinuation<Void, Never>?
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func resume() {
        signalled = true
        waiting?.resume()
        waiting = nil
    }
}
