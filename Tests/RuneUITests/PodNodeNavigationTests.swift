import AppKit
import RuneCore
import RuneFakeK8sSupport
import RuneStore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class PodNodeNavigationTests: XCTestCase {
    func testBackFromNodeRestoresFilteredPodAndKeepsForwardHistoryInConnectedWindow() async throws {
        let server = try await RuneFakeK8sRESTServer.start()
        defer { server.stop() }
        let configURL = FileManager.default.temporaryDirectory.appendingPathComponent("node-back-\(UUID().uuidString).yaml")
        try server.kubeconfigYAML().write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }
        let context = KubeContext(name: RuneFakeK8sFixture.defaultContextName)
        let first = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", nodeName: "orbit-node-a", containerNamesLine: "lens")
        let original = PodSummary(name: "ember-gate-75c9f746b8-kq2wm", namespace: "alpha-zone", status: "Running", nodeName: "orbit-node-b", containerNamesLine: "gate, metrics")
        let state = makeState(pod: original)
        state.setPods([first, original])
        state.setSelectedPod(original)
        state.setContexts([context])
        state.selectedContext = context
        state.setSources([KubeConfigSource(url: configURL)])
        state.resourceSearchQuery = "ember"
        let model = RuneAppViewModel(state: state,
            overviewSnapshotPersistence: NoopOverviewSnapshotCacheStore(),
            namespaceListPersistence: NoopNamespaceListPersistenceStore())
        let host = NSHostingController(rootView: RuneRootView(viewModel: model,
            onLayoutSnapshotChange: nil, debugDisableBootstrap: true,
            initialPodInspectorTab: .logs, shellVariant: .appKitSplitView)
            .frame(width: 1400, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
        }
        for _ in 0..<10 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        model.openPodNode(original)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(state.selectedWorkloadKind, .node)
        model.navigateBack()
        XCTAssertEqual(state.selectedWorkloadKind, .pod)
        XCTAssertEqual(state.selectedPod?.id, original.id, "Back must restore the Pod before a background refresh finishes.")
        for _ in 0..<30 {
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(state.selectedContext?.name, context.name)
        XCTAssertEqual(state.selectedNamespace, original.namespace)
        XCTAssertEqual(state.resourceSearchQuery, "ember")
        XCTAssertEqual(state.selectedPod?.id, original.id)
        XCTAssertTrue(model.canNavigateForward, "Restoration must not add a new history entry or discard the Node destination.")
        model.navigateForward()
        XCTAssertEqual(state.selectedWorkloadKind, .node)
        XCTAssertEqual(state.selectedNode?.name, original.nodeName)
    }

    func testNodeLinkUsesClickedPodIdentityAcrossPendingRowReorders() throws {
        let first = PodSummary(name: "api-a", namespace: "payments", status: "Running", nodeName: "node-a")
        let second = PodSummary(name: "api-b", namespace: "payments", status: "Running", nodeName: "node-b")
        let pending = PodSummary(name: "pending", namespace: "payments", status: "Pending")
        var opened: [String] = []
        let onOpen: (PodSummary) -> Void = { opened.append($0.nodeName ?? "") }
        let host = NSHostingView(rootView: makeTable(pods: [first, second, pending], onOpen: onOpen)
            .frame(width: 1100, height: 240))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 240)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "node" })
        let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: column, row: 1))
        let button = try XCTUnwrap(descendants(cell).compactMap { $0 as? NSButton }.first)
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel(), "Open node node-b")
        button.performClick(nil)
        XCTAssertEqual(opened, ["node-b"])
        XCTAssertEqual(table.selectedRow, 0, "Opening another Pod's node must not depend on row selection.")

        let coordinator = try XCTUnwrap(table.delegate as? AppKitPodTableView.Coordinator)
        let updated = PodSummary(name: second.name, namespace: second.namespace, status: "Running", nodeName: "node-c")
        coordinator.parent = makeTable(pods: [updated, first, pending], onOpen: onOpen)
        button.performClick(nil)
        XCTAssertEqual(opened, ["node-b", "node-c"], "Resolve the current Pod by identity rather than a stale row index.")

        coordinator.parent = makeTable(pods: [first, pending], onOpen: onOpen)
        button.performClick(nil)
        XCTAssertEqual(opened, ["node-b", "node-c"], "A removed Pod's old cell must not navigate to another Pod's node.")

        let pendingCell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: column, row: 2))
        let pendingButton = try XCTUnwrap(descendants(pendingCell).compactMap { $0 as? NSButton }.first)
        XCTAssertFalse(pendingButton.isEnabled)
        XCTAssertEqual(pendingButton.title, "—")
        pendingButton.performClick(nil)
        XCTAssertEqual(opened, ["node-b", "node-c"])
    }

    func testNodeNavigationReusesCachedSummaryAndReturnsToPods() {
        let pod = PodSummary(name: "api", namespace: "payments", status: "Running", nodeName: "node-a")
        let node = ClusterResourceSummary(kind: .node, name: "node-a", namespace: nil, primaryText: "Ready", secondaryText: "v1.34.0")
        let state = makeState(pod: pod)
        state.setNodes([node])
        state.resourceSearchQuery = "api"
        let model = RuneAppViewModel(state: state)
        model.isDetailPaneVisible = false
        model.openPodNode(pod)

        XCTAssertEqual(state.selectedSection, .storage)
        XCTAssertEqual(state.selectedWorkloadKind, .node)
        XCTAssertEqual(state.selectedNode, node)
        XCTAssertEqual(state.nodes, [node])
        XCTAssertEqual(state.resourceSearchQuery, "")
        XCTAssertTrue(model.isDetailPaneVisible)
        XCTAssertTrue(model.canNavigateBack)
        model.navigateBack()
        XCTAssertEqual(state.selectedSection, .workloads)
        XCTAssertEqual(state.selectedWorkloadKind, .pod)
        XCTAssertEqual(state.selectedPod?.id, pod.id)
        XCTAssertEqual(state.resourceSearchQuery, "api")
    }

    func testNodeNavigationLoadsNamedDetailsWithoutAnExistingNodeList() async throws {
        let pod = PodSummary(name: "api", namespace: "payments", status: "Running", nodeName: "node-b")
        let state = makeState(pod: pod)
        let context = KubeContext(name: "node-navigation-test")
        state.setContexts([context])
        state.selectedContext = context
        let recorder = NodeRequestRecorder()
        let model = RuneAppViewModel(state: state, resourceManifestLoad: { _, context, _, kind, name in
            recorder.requests.append((context.name, kind, name))
            return ("kind: Node\nmetadata:\n  name: \(name)\n", "Name: \(name)\nConditions: Ready=True")
        })

        XCTAssertTrue(state.nodes.isEmpty)
        model.openPodNode(pod)
        for _ in 0..<50 where state.resourceDescribe.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(recorder.requests.count, 1)
        XCTAssertEqual(recorder.requests.first?.0, context.name)
        XCTAssertEqual(recorder.requests.first?.1, .node)
        XCTAssertEqual(recorder.requests.first?.2, "node-b")
        XCTAssertEqual(state.selectedNode?.name, "node-b")
        XCTAssertNil(state.selectedNode?.namespace)
        XCTAssertTrue(state.resourceDescribe.contains("Name: node-b"))
        XCTAssertTrue(state.resourceYAML.contains("kind: Node"))
        XCTAssertEqual(state.nodes.map(\.name), ["node-b"])
    }

    func testUnscheduledPodDoesNotChangeNavigationOrOpenInspector() {
        let nodeNames: [String?] = [nil, "", " \n "]
        for nodeName in nodeNames {
            let pod = PodSummary(name: "pending", namespace: "payments", status: "Pending", nodeName: nodeName)
            let state = makeState(pod: pod)
            let model = RuneAppViewModel(state: state)
            model.isDetailPaneVisible = false
            model.openPodNode(pod)
            XCTAssertEqual(state.selectedSection, .workloads)
            XCTAssertEqual(state.selectedWorkloadKind, .pod)
            XCTAssertNil(state.selectedNode)
            XCTAssertFalse(model.canNavigateBack)
            XCTAssertFalse(model.isDetailPaneVisible)
        }
    }

    private func makeState(pod: PodSummary) -> RuneAppState {
        let state = RuneAppState()
        state.selectedSection = .workloads
        state.selectedWorkloadKind = .pod
        state.selectedNamespace = pod.namespace
        state.setPods([pod])
        state.setSelectedPod(pod)
        return state
    }

    private func makeTable(pods: [PodSummary], onOpen: @escaping (PodSummary) -> Void) -> AppKitPodTableView {
        AppKitPodTableView(
            pods: pods,
            selectedPodID: pods.first?.id,
            selectedPodIDs: [],
            sortColumn: .name,
            sortAscending: true,
            nameColumnWidth: 260,
            canApplyClusterMutations: false,
            isFavorite: { _ in false },
            onSelectPod: { _ in },
            onToggleBulkSelection: { _ in },
            onToggleSort: { _ in },
            onNameColumnWidthChanged: { _ in },
            onToggleFavorite: { _ in },
            onOpenLogs: { _ in },
            onOpenExec: { _ in },
            onOpenDescribe: { _ in },
            onOpenYAML: { _ in },
            onDelete: { _ in },
            onOpenNode: onOpen
        )
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor
private final class NodeRequestRecorder {
    var requests: [(String, KubeResourceKind, String)] = []
}
