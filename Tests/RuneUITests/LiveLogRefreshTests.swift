import AppKit
import RuneCore
import RuneFakeK8sSupport
import RuneStore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class LiveLogRefreshTests: XCTestCase {
    func testTailToolbarStartWaitsForSlowReadAndDisplaysNewSnapshots() async throws {
        let pod = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        let target = "/api/v1/namespaces/alpha-zone/pods/\(pod.name)/log?tailLines=200&container=lens"
        let fixture = RuneFakeK8sFixture(
            delayedResponseTargets: [target: 3_600_000_000],
            logResponseSequences: [target: ["seq=1\n", "seq=1\nseq=2 newest\n"]]
        )
        let server = try await RuneFakeK8sRESTServer.start(fixture: fixture)
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        model.state.setPods([pod])
        model.state.setSelectedPod(pod)
        // The toolbar writes both bindings when starting Tail.
        model.isLogTailModeEnabled = true
        model.isLogStreamPaused = false
        try await waitUntil { model.state.podLogs.contains("seq=1") && !model.state.isLoadingLogs }
        XCTAssertEqual(logRequests(server, pod: pod).count, 1, "Do not cancel a slow read when the three-second timer fires.")
        try await waitUntil { model.state.podLogs.contains("seq=2 newest") }
        XCTAssertEqual(logRequests(server, pod: pod).count, 2)
    }

    func testTailContinuesAfterChangingPodsAndHonorsPauseAndStop() async throws {
        let server = try await RuneFakeK8sRESTServer.start()
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        let first = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        let second = PodSummary(name: "ember-gate-75c9f746b8-kq2wm", namespace: "alpha-zone", status: "Running", containerNamesLine: "gate, metrics")
        model.state.setPods([first, second])
        model.state.setSelectedPod(first)
        model.isLogTailModeEnabled = true
        try await waitUntil { !model.state.isLoadingLogs && model.state.lastLogUpdatedAt != nil }

        model.selectPod(second)
        try await waitUntil {
            !model.state.isLoadingResourceDetails && !model.state.isLoadingLogs
                && model.state.podLogs.contains(second.name)
        }
        server.resetRequestLines()
        try await waitUntil { self.logRequests(server, pod: second).count >= 1 }

        model.toggleLogStreamPause()
        try await waitUntil { !model.state.isLoadingLogs }
        let pausedCount = logRequests(server, pod: second).count
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertEqual(logRequests(server, pod: second).count, pausedCount)
        model.toggleLogStreamPause()
        try await waitUntil { self.logRequests(server, pod: second).count > pausedCount }

        model.isLogTailModeEnabled = false
        try await waitUntil { !model.state.isLoadingLogs }
        let stoppedCount = logRequests(server, pod: second).count
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertEqual(logRequests(server, pod: second).count, stoppedCount)
    }

    func testTailRetriesAfterAFailedRead() async throws {
        let fixture = RuneFakeK8sFixture(selfSubjectAccessReviewDenials: [
            RuneFakeK8sRBACRule(namespace: "alpha-zone", verb: "get", resource: "pods", subresource: "log")
        ])
        let server = try await RuneFakeK8sRESTServer.start(fixture: fixture)
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        let pod = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        model.state.setPods([pod])
        model.state.setSelectedPod(pod)
        model.isLogTailModeEnabled = true
        try await waitUntil { model.state.lastLogFetchError != nil && !model.state.isLoadingLogs }
        server.resetRequestLines()
        try await waitUntil { !self.logRequests(server, pod: pod).isEmpty }
        XCTAssertTrue(model.isLogTailModeEnabled)
    }

    func testRegularLogsFollowLatestAndPreserveTheViewerDuringRefresh() async throws {
        try await verifyLogViewport(large: false)
    }

    func testLargeLogsFollowLatestAndResumeAfterPause() async throws {
        try await verifyLogViewport(large: true)
    }

    private func verifyLogViewport(large: Bool) async throws {
        let count = large ? 1400 : 400
        let payload = String(repeating: " synthetic", count: large ? 30 : 12)
        func snapshot(_ offset: Int) -> String {
            (offset..<(count + offset)).map { "line-\($0)\(payload)" }.joined(separator: "\n")
        }
        let model = LiveLogViewportModel(text: snapshot(0))
        let host = NSHostingController(rootView: LiveLogViewportHarness(model: model)
            .frame(width: 760, height: 420))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
        }
        try await settle(window)
        let scroll = try XCTUnwrap(logScrollView(in: host.view))
        assertAtEnd(scroll)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1, "Following the last line must keep the start of long messages visible.")
        model.isLoading = true
        try await settle(window)
        XCTAssertTrue(logScrollView(in: host.view) === scroll, "A background refresh must keep the existing log viewport mounted.")

        model.update(text: snapshot(1)) // A rolling log window can keep the same line count.
        model.isLoading = false
        try await settle(window)
        let refreshedScroll = try XCTUnwrap(logScrollView(in: host.view))
        assertAtEnd(refreshedScroll)
        XCTAssertEqual(refreshedScroll.contentView.bounds.minX, 0, accuracy: 1)

        model.followsLatest = false
        try await settle(window)
        let pausedScroll = try XCTUnwrap(logScrollView(in: host.view))
        pausedScroll.contentView.scroll(to: .zero)
        pausedScroll.reflectScrolledClipView(pausedScroll.contentView)
        model.update(text: snapshot(2))
        try await settle(window)
        XCTAssertLessThan(try XCTUnwrap(logScrollView(in: host.view)).contentView.bounds.minY, 40)

        model.followsLatest = true
        try await settle(window)
        assertAtEnd(try XCTUnwrap(logScrollView(in: host.view)))
    }

    private func assertAtEnd(_ scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line) {
        let height = scroll.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(height, scroll.contentView.bounds.height * 2, file: file, line: line)
        XCTAssertGreaterThan(scroll.contentView.bounds.maxY, height - 40, file: file, line: line)
    }

    private func logScrollView(in view: NSView) -> NSScrollView? {
        var candidates = view.subviews.compactMap { logScrollView(in: $0) }
        if let scroll = view as? NSScrollView { candidates.append(scroll) }
        return candidates.max { ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func makeModel(server: RuneFakeK8sRESTServer) throws -> (RuneAppViewModel, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-log-\(UUID().uuidString).yaml")
        try server.kubeconfigYAML().write(to: url, atomically: true, encoding: .utf8)
        let state = RuneAppState()
        state.setSources([KubeConfigSource(url: url)])
        state.selectedContext = KubeContext(name: RuneFakeK8sFixture.defaultContextName)
        state.selectedNamespace = "alpha-zone"
        state.selectedSection = .workloads
        state.selectedWorkloadKind = .pod
        return (RuneAppViewModel(state: state, savedWorkspaceStore: EmptyLiveLogWorkspaceStore(),
                                overviewSnapshotPersistence: NoopOverviewSnapshotCacheStore(),
                                namespaceListPersistence: NoopNamespaceListPersistenceStore()), url)
    }

    private func logRequests(_ server: RuneFakeK8sRESTServer, pod: PodSummary) -> [String] {
        server.requestLines().filter { $0.contains("/pods/\(pod.name)/log") }
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for the log refresh.")
                throw URLError(.timedOut)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct EmptyLiveLogWorkspaceStore: SavedWorkspaceStoring {
    func loadSavedWorkspaces() -> [SavedWorkspaceSnapshot] { [] }
    func saveSavedWorkspaces(_ workspaces: [SavedWorkspaceSnapshot]) {}
}

@MainActor
private final class LiveLogViewportModel: ObservableObject {
    @Published var text: String
    @Published var result: ResourceLogSearchResult
    @Published var isLoading = false
    @Published var followsLatest = true

    init(text: String) {
        self.text = text
        result = ResourceLogSearchResult.makeForInspector(text: text, query: "")
    }

    func update(text: String) {
        self.text = text
        result = ResourceLogSearchResult.makeForInspector(text: text, query: "")
    }
}

private struct LiveLogViewportHarness: View {
    @ObservedObject var model: LiveLogViewportModel

    var body: some View {
        ResourceLogsOutputSurface(
            isLoadingLogs: model.isLoading, isLoadingResources: false, errorMessage: nil,
            logText: model.text, renderSearchResult: model.result, navigationSearchResult: nil,
            selectedSearchMatchIndex: 0, searchNavigationSequence: 0,
            emptyTitle: "No output", emptyMessage: "No output", noMatchesMessage: "No matches",
            readOnlyResetID: "live-logs", onReload: {}, presentationStyle: .regular,
            followsLatestLogs: model.followsLatest
        )
    }
}
