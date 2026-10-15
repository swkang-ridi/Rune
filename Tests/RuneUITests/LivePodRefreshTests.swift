import Foundation
import RuneCore
import RuneFakeK8sSupport
import RuneStore
import XCTest
@testable import RuneUI

@MainActor
final class LivePodRefreshTests: XCTestCase {
    private let podPath = "/api/v1/namespaces/alpha-zone/pods"
    private let metricsPath = "/apis/metrics.k8s.io/v1beta1/namespaces/alpha-zone/pods"
    private let podName = "orbit-lens-6f58d7d89b-hx9q2"
    private let otherPodName = "ember-gate-75c9f746b8-kq2wm"

    func testWatchChangesReachRowsBeforeSlowSnapshotAndSurviveItsCompletion() async throws {
        let body = try lines([
            podEvent("MODIFIED", name: podName, phase: "Failed", version: "41"),
            podEvent("ADDED", name: "new-live-pod", phase: "Pending", version: "42"),
            ["type": "DELETED", "object": ["kind": "Pod", "metadata": ["name": otherPodName, "namespace": "alpha-zone", "resourceVersion": "43"]]],
            podEvent("MODIFIED", name: "foreign-pod", phase: "Running", version: "44", namespace: "bravo-zone")
        ])
        let harness = try await makeHarness(fixture: RuneFakeK8sFixture(
            delayedResponseTargets: ["/api/v1/nodes": 2_000_000_000],
            watchResponseSequencesByPath: [podPath: [body, bookmark]]
        ))
        defer { harness.cleanup() }
        harness.model.state.setPods([
            PodSummary(name: podName, namespace: "alpha-zone", status: "Running", cpuUsage: "1m", memoryUsage: "2Mi"),
            PodSummary(name: otherPodName, namespace: "alpha-zone", status: "Running")
        ])
        let start = ContinuousClock.now
        harness.model.isLiveStatusUpdatesEnabled = true
        try await waitUntil(timeout: 1.5) {
            harness.model.state.pods.first { $0.name == self.podName }?.status == "Failed"
                && harness.model.state.pods.contains { $0.name == "new-live-pod" }
                && !harness.model.state.pods.contains { $0.name == self.otherPodName }
        }
        XCTAssertLessThan(start.duration(to: ContinuousClock.now), .seconds(1), "Watch updates must not wait for a two-second Node/list read.")
        XCTAssertTrue(harness.model.state.isLoading)
        XCTAssertEqual(harness.model.state.selectedPod?.status, "Failed")
        XCTAssertEqual(harness.model.state.selectedPod?.cpuUsage, "1m", "Watch payloads do not contain metrics; keep the last reading.")
        XCTAssertFalse(harness.model.state.pods.contains { $0.namespace != "alpha-zone" })
        XCTAssertEqual(harness.store.snapshot(context: harness.context, namespace: "alpha-zone").pods, harness.model.state.pods)

        try await waitUntil { !harness.model.state.isLoading }
        XCTAssertEqual(harness.model.state.pods.first { $0.name == self.podName }?.status, "Failed", "An older list response must not undo a watch update.")
        XCTAssertTrue(harness.model.state.pods.contains { $0.name == "new-live-pod" })
        XCTAssertFalse(harness.model.state.pods.contains { $0.name == self.otherPodName })
        XCTAssertEqual(fullPodLists(harness.server).count, 1, "A watch burst must not trigger a list request per event.")
    }

    func testMetricsRefreshIndependentlyWithoutRevertingNewerStatusAndStopWithLive() async throws {
        let modified = try lines([podEvent("MODIFIED", name: podName, phase: "Failed", version: "45")])
        let fixture = RuneFakeK8sFixture(
            delayedResponseTargets: [metricsPath: 1_500_000_000],
            watchResponseSequencesByPath: [podPath: Array(repeating: bookmark, count: 7) + [modified, bookmark]]
        )
        let harness = try await makeHarness(fixture: fixture)
        defer { harness.cleanup() }
        harness.model.isLiveStatusUpdatesEnabled = true
        try await waitUntil { !harness.model.state.isLoading && !harness.model.state.pods.isEmpty }
        harness.model.state.setPods(harness.model.state.pods.map { $0.updatingResourceUsage(cpu: "1m", memory: "2Mi") })
        let listCount = fullPodLists(harness.server).count
        let selectedPodLogs = harness.server.requestLines().filter { $0.contains(self.podPath + "/" + self.otherPodName + "/log?") }.count
        try await waitUntil(timeout: 8) {
            let pod = harness.model.state.pods.first { $0.name == self.podName }
            return pod?.status == "Failed" && pod?.cpuUsage == "42m"
        }
        XCTAssertEqual(fullPodLists(harness.server).count, listCount, "Metrics must refresh without refetching the Pod list.")
        XCTAssertEqual(harness.model.state.pods.first { $0.name == self.podName }?.nodeName, "orbit-node-b")
        XCTAssertEqual(harness.server.requestLines().filter { $0.contains(self.podPath + "/" + self.otherPodName + "/log?") }.count, selectedPodLogs, "An unrelated Pod event must not reload the selected Pod's logs.")
        harness.model.isLiveStatusUpdatesEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        let metricsCount = harness.server.requestLines().filter { $0.contains(self.metricsPath) }.count
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(harness.server.requestLines().filter { $0.contains(self.metricsPath) }.count, metricsCount)
    }

    func testExpiredWatchResynchronizesAndReconnectsWithoutExpiredVersion() async throws {
        let expired = try lines([
            ["type": "BOOKMARK", "object": ["metadata": ["resourceVersion": "expired-40"]]],
            ["type": "ERROR", "object": ["kind": "Status", "code": 410, "message": "too old resource version"]]
        ])
        let recovered = try lines([podEvent("MODIFIED", name: podName, phase: "Succeeded", version: "46")])
        let harness = try await makeHarness(fixture: RuneFakeK8sFixture(watchResponseSequencesByPath: [podPath: [expired, recovered, bookmark]]))
        defer { harness.cleanup() }
        harness.model.isLiveStatusUpdatesEnabled = true
        try await waitUntil { harness.model.state.pods.first { $0.name == self.podName }?.status == "Succeeded" }
        let requests = harness.server.requestLines().filter { $0.contains(self.podPath + "?") && $0.contains("watch=1") }
        XCTAssertGreaterThanOrEqual(requests.count, 2)
        XCTAssertFalse(requests[1].contains("resourceVersion="))
        XCTAssertFalse(requests.contains { $0.contains("resourceVersionMatch=") })
        XCTAssertNil(harness.model.state.lastError)
    }

    func testSlowInspectorCannotRestoreTheStatusFromBeforeAWatchEvent() async throws {
        let modified = try lines([podEvent("MODIFIED", name: podName, phase: "Failed", version: "48")])
        let harness = try await makeHarness(fixture: RuneFakeK8sFixture(
            delayedResponseTargets: [podPath + "/" + podName: 1_500_000_000],
            watchResponseSequencesByPath: [podPath: [bookmark, bookmark, modified, bookmark]]
        ))
        defer { harness.cleanup() }
        harness.model.state.setPods([PodSummary(name: podName, namespace: "alpha-zone", status: "Running")])
        harness.model.isLiveStatusUpdatesEnabled = true
        try await waitUntil {
            harness.model.state.selectedPod?.status == "Failed" && harness.model.state.isLoadingResourceDetails
        }
        try await waitUntil { !harness.model.state.isLoadingResourceDetails }
        XCTAssertEqual(harness.model.state.selectedPod?.status, "Failed")
        XCTAssertEqual(harness.model.state.selectedPod?.nodeName, "orbit-node-b")
        XCTAssertEqual(harness.model.state.pods.first { $0.name == self.podName }?.status, "Failed")
    }

    func testPendingWatchChangesDoNotLeakAfterNamespaceSwitch() async throws {
        let target = podPath + "?watch=1&allowWatchBookmarks=true&timeoutSeconds=290"
        let body = try lines([podEvent("MODIFIED", name: podName, phase: "Failed", version: "47")])
        let harness = try await makeHarness(fixture: RuneFakeK8sFixture(
            delayedResponseTargets: [target: 400_000_000],
            watchResponseSequencesByPath: [podPath: [body, bookmark]]
        ))
        defer { harness.cleanup() }
        harness.model.isLiveStatusUpdatesEnabled = true
        try await waitUntil { harness.server.requestLines().contains { $0.contains("watch=1") } }
        harness.model.setNamespace("bravo-zone")
        try await waitUntil { !harness.model.state.isLoading && harness.model.state.pods.map(\.namespace) == ["bravo-zone"] }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(harness.model.state.pods.map(\.namespace), ["bravo-zone"])
        XCTAssertFalse(harness.model.state.pods.contains { $0.name == self.podName })
    }

    private var bookmark: String { "{\"type\":\"BOOKMARK\",\"object\":{\"metadata\":{\"resourceVersion\":\"40\"}}}\n" }

    private func podEvent(_ type: String, name: String, phase: String, version: String, namespace: String = "alpha-zone") -> [String: Any] {
        ["type": type, "object": [
            "apiVersion": "v1", "kind": "Pod",
            "metadata": ["name": name, "namespace": namespace, "resourceVersion": version, "labels": ["live": "updated"]],
            "spec": ["nodeName": "orbit-node-b", "containers": [["name": "lens", "image": "synthetic:v2"]]],
            "status": ["phase": phase, "podIP": "10.42.0.99", "containerStatuses": [["name": "lens", "ready": false, "restartCount": 3]]]
        ]]
    }

    private func lines(_ events: [[String: Any]]) throws -> String {
        try events.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
    }

    private func fullPodLists(_ server: RuneFakeK8sRESTServer) -> [String] {
        server.requestLines().filter { $0.hasPrefix("GET \(podPath) ") }
    }

    private struct Harness {
        let model: RuneAppViewModel
        let store: ResourceStore
        let server: RuneFakeK8sRESTServer
        let context: KubeContext
        let url: URL
        @MainActor func cleanup() {
            model.isLiveStatusUpdatesEnabled = false
            model.isLogTailModeEnabled = false
            server.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeHarness(fixture: RuneFakeK8sFixture) async throws -> Harness {
        let server = try await RuneFakeK8sRESTServer.start(fixture: fixture)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-pods-\(UUID().uuidString).yaml")
        try server.kubeconfigYAML().write(to: url, atomically: true, encoding: .utf8)
        let state = RuneAppState()
        let context = KubeContext(name: RuneFakeK8sFixture.defaultContextName)
        state.setSources([KubeConfigSource(url: url)])
        state.setContexts([context])
        state.selectedContext = context
        state.selectedNamespace = "alpha-zone"
        state.selectedSection = .workloads
        state.selectedWorkloadKind = .pod
        let store = ResourceStore()
        let model = RuneAppViewModel(
            state: state, store: store, savedWorkspaceStore: EmptyLivePodWorkspaceStore(),
            overviewSnapshotPersistence: NoopOverviewSnapshotCacheStore(), namespaceListPersistence: NoopNamespaceListPersistenceStore(),
            resourceManifestLoad: { _, _, namespace, kind, name in ("kind: \(kind.rawValue)\nmetadata:\n  name: \(name)\n  namespace: \(namespace)\n", "Name: \(name)") }
        )
        return Harness(model: model, store: store, server: server, context: context, url: url)
    }

    private func waitUntil(timeout: TimeInterval = 6, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Timed out waiting for live Pod data."); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct EmptyLivePodWorkspaceStore: SavedWorkspaceStoring {
    func loadSavedWorkspaces() -> [SavedWorkspaceSnapshot] { [] }
    func saveSavedWorkspaces(_ workspaces: [SavedWorkspaceSnapshot]) {}
}
