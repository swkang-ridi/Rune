import Combine
import XCTest
@testable import RuneCore

@MainActor
final class LogSnapshotPresentationTests: XCTestCase {
    func testIdenticalPodReadsKeepDocumentAndCacheStableWhileStatusAdvances() {
        let state = RuneAppState()
        var documents: [String] = []
        var cacheUpdates = 0
        let documentSubscription = state.$podLogs.dropFirst().sink { documents.append($0) }
        let cacheSubscription = state.$sessionLogCache.dropFirst().sink { _ in cacheUpdates += 1 }
        defer {
            documentSubscription.cancel()
            cacheSubscription.cancel()
        }

        func read(_ text: String, at time: TimeInterval) {
            state.replacePodLogRead(text, contextName: "ctx", namespace: "ns", podName: "pod",
                                    loadedAt: Date(timeIntervalSince1970: time))
        }
        read("first\n", at: 100)
        let initialDocument = state.podLogs
        read("first\n", at: 200)
        XCTAssertEqual(documents.count, 1, "An unchanged poll must not publish a new log document.")
        XCTAssertEqual(cacheUpdates, 1)
        XCTAssertEqual(state.lastLogUpdatedAt, Date(timeIntervalSince1970: 200))

        read("first\nsecond\n", at: 300)
        XCTAssertTrue(state.podLogs.hasPrefix(initialDocument), "New lines must retain the existing document prefix.")
        XCTAssertEqual(documents.count, 2)
        XCTAssertEqual(cacheUpdates, 2)

        read("second\nthird\n", at: 400)
        XCTAssertFalse(state.podLogs.contains("first"), "A rolling snapshot must not duplicate prior responses.")
        XCTAssertTrue(state.podLogs.contains("second\nthird"))
    }

    func testIdenticalUnifiedReadsKeepDocumentAndSourcesStable() {
        let state = RuneAppState()
        var documentUpdates = 0
        var sourceUpdates = 0
        let documentSubscription = state.$unifiedServiceLogs.dropFirst().sink { _ in documentUpdates += 1 }
        let sourceSubscription = state.$unifiedServiceLogPods.dropFirst().sink { _ in sourceUpdates += 1 }
        defer {
            documentSubscription.cancel()
            sourceSubscription.cancel()
        }

        for time in [100.0, 200.0] {
            state.replaceUnifiedServiceLogRead("[pod] first\n", pods: ["pod"], contextName: "ctx",
                                              namespace: "ns", kind: .service, resourceName: "service",
                                              loadedAt: Date(timeIntervalSince1970: time))
        }
        XCTAssertEqual(documentUpdates, 1)
        XCTAssertEqual(sourceUpdates, 1)
        XCTAssertEqual(state.lastLogUpdatedAt, Date(timeIntervalSince1970: 200))
    }
}
