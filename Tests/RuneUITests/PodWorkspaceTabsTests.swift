import AppKit
import RuneCore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class PodWorkspaceTabsTests: XCTestCase {
    func testPodsOpenInClosableTabsInsideTheListWindow() async throws {
        let first = PodSummary(name: "payment-api-a", namespace: "payments", status: "Running", nodeName: "worker-a",
                               containerNamesLine: "spark-kubernetes-driver", initContainerNamesLine: "fetch-code")
        let second = PodSummary(name: "payment-api-b", namespace: "payments", status: "Running", nodeName: "worker-b",
                                containerNamesLine: "api")
        let state = RuneAppState()
        state.selectedSection = .workloads
        state.selectedWorkloadKind = .pod
        state.selectedNamespace = first.namespace
        state.setPods([first, second])
        state.resourceSearchQuery = "payment"
        let model = RuneAppViewModel(state: state)
        let host = NSHostingController(rootView: RuneRootView(
            viewModel: model, onLayoutSnapshotChange: nil, debugDisableBootstrap: true,
            shellVariant: .appKitSplitView, initialSidebarWidthOverride: 220
        ).frame(width: 1400, height: 900))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            model.isLogTailModeEnabled = false
            window.orderOut(nil)
            window.contentViewController = nil
        }
        try await settle(window)
        let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first)
        let coordinator = try XCTUnwrap(table.delegate as? AppKitPodTableView.Coordinator)

        coordinator.activatePod(at: 0)
        try await settle(window)
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "rune.pod-inspector-window" })
        XCTAssertTrue(model.isLogTailModeEnabled)
        XCTAssertEqual(model.selectedLogPreset, .recentMinutes)
        XCTAssertEqual(model.selectedLogContainer, "spark-kubernetes-driver")
        let containerPicker = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(containerPicker.itemTitles, ["All containers", "spark-kubernetes-driver", "fetch-code (init)"])
        XCTAssertEqual(containerPicker.titleOfSelectedItem, "spark-kubernetes-driver")
        containerPicker.selectItem(at: 2)
        containerPicker.sendAction(containerPicker.action, to: containerPicker.target)
        try await settle(window)
        XCTAssertEqual(model.selectedLogContainer, "fetch-code")
        state.setPodLogs("first pod latest log")
        try await settle(window)
        let logView = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor })
        XCTAssertTrue(logView.string.contains("first pod latest log"))
        XCTAssertGreaterThan(try XCTUnwrap(logView.enclosingScrollView).bounds.height, 700)
        XCTAssertEqual(tabIDs(in: host.view).filter { $0 == "pod-tab:\(first.id)" }.count, 1)
        try savePreview(host.view, name: "pod-log-tab")

        try press("pod-list-tab", in: host.view)
        try await settle(window)
        XCTAssertFalse(model.isLogTailModeEnabled, "Only the visible log tab should poll.")
        XCTAssertEqual(state.resourceSearchQuery, "payment")
        XCTAssertTrue(descendants(host.view).contains { $0 === table }, "Returning to Pods must retain the native list.")
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        coordinator.activatePod(at: 1)
        try await settle(window)
        XCTAssertEqual(state.selectedPod?.id, second.id)
        XCTAssertEqual(model.selectedLogContainer, "api", "A new Pod tab must select its main container.")
        XCTAssertTrue(model.isLogTailModeEnabled)
        XCTAssertTrue(tabIDs(in: host.view).contains("pod-tab:\(first.id)"))
        XCTAssertTrue(tabIDs(in: host.view).contains("pod-tab:\(second.id)"))
        try savePreview(host.view, name: "multiple-pod-tabs")

        try press("pod-tab:\(first.id)", in: host.view)
        try await settle(window)
        XCTAssertEqual(state.selectedPod?.id, first.id)
        XCTAssertEqual(model.selectedLogContainer, "fetch-code", "Container choice must be retained per Pod tab.")
        XCTAssertEqual(descendants(host.view).compactMap { $0 as? NSPopUpButton }.first?.titleOfSelectedItem, "fetch-code (init)")
        state.setPodLogs("first pod switched back")
        try await settle(window)
        XCTAssertTrue(descendants(host.view).compactMap { $0 as? NSTextView }.contains { $0.string.contains("first pod switched back") })

        coordinator.parent.onOpenYAML(first)
        try await settle(window)
        XCTAssertFalse(model.isLogTailModeEnabled)
        try press("pod-tab:\(second.id)", in: host.view)
        try await settle(window)
        XCTAssertTrue(model.isLogTailModeEnabled)
        try press("pod-tab:\(first.id)", in: host.view)
        try await settle(window)
        XCTAssertFalse(model.isLogTailModeEnabled, "Each Pod tab must retain its selected inspector page.")
        coordinator.parent.onOpenLogs(first)
        try await settle(window)
        XCTAssertTrue(model.isLogTailModeEnabled)

        try press("pod-list-tab", in: host.view)
        try await settle(window)
        coordinator.activatePod(at: 0)
        try await settle(window)
        XCTAssertEqual(tabIDs(in: host.view).filter { $0 == "pod-tab:\(first.id)" }.count, 1, "Reopening a Pod must reuse its tab.")
        try press("close-pod-tab:\(first.id)", in: host.view)
        try await settle(window)
        XCTAssertEqual(state.selectedPod?.id, second.id)
        XCTAssertFalse(tabIDs(in: host.view).contains("pod-tab:\(first.id)"))
        XCTAssertTrue(model.isLogTailModeEnabled)
        try press("close-pod-tab:\(second.id)", in: host.view)
        try await settle(window)
        XCTAssertFalse(model.isLogTailModeEnabled)
        XCTAssertFalse(tabIDs(in: host.view).contains("pod-list-tab"))
        XCTAssertTrue(descendants(host.view).contains { $0 === table })

        coordinator.activatePod(at: 0)
        try await settle(window)
        coordinator.parent.onOpenNode?(first)
        try await settle(window)
        XCTAssertEqual(state.selectedWorkloadKind, .node)
        XCTAssertFalse(model.isLogTailModeEnabled)
        model.navigateBack()
        try await settle(window)
        XCTAssertEqual(state.selectedWorkloadKind, .pod)
        XCTAssertTrue(tabIDs(in: host.view).contains("pod-tab:\(first.id)"))
        XCTAssertFalse(model.isLogTailModeEnabled, "Back from a Node returns to the Pod list.")
        try press("pod-tab:\(first.id)", in: host.view)
        try await settle(window)
        XCTAssertTrue(model.isLogTailModeEnabled)
        state.selectedNamespace = "other"
        try await settle(window)
        XCTAssertFalse(model.isLogTailModeEnabled)
        XCTAssertFalse(tabIDs(in: host.view).contains("pod-tab:\(first.id)"), "A namespace change must discard tabs from the previous scope.")
    }

    private func tabIDs(in view: NSView) -> [String] {
        descendants(view).compactMap { ($0 as? NSButton)?.accessibilityIdentifier() }
    }

    private func press(_ id: String, in view: NSView) throws {
        let button = try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == id
        }, id)
        button.performClick(nil)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<12 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func savePreview(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["RUNE_POD_TABS_PREVIEW_DIR"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent("\(name).png"))
    }
}
