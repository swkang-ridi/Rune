import AppKit
import RuneCore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class PodInspectorWindowTests: XCTestCase {
    func testPodActivationReusesSeparateWindowAndKeepsLogsLiveAfterClosingAndReopening() async throws {
        let defaults = UserDefaults.standard
        let minutesKey = RuneSettingsKeys.logsRecentWindowMinutes
        let savedMinutes = defaults.object(forKey: minutesKey)
        defaults.runeRecentLogWindowMinutes = 7
        defer {
            if let savedMinutes { defaults.set(savedMinutes, forKey: minutesKey) }
            else { defaults.removeObject(forKey: minutesKey) }
        }
        let first = PodSummary(name: "payment-api-a", namespace: "payments", status: "Running", nodeName: "worker-a")
        let second = PodSummary(name: "payment-api-b", namespace: "payments", status: "Running", nodeName: "worker-b")
        let state = RuneAppState()
        state.selectedSection = .workloads
        state.selectedWorkloadKind = .pod
        state.selectedNamespace = first.namespace
        state.setPods([first, second])
        state.setPodLogs("seq=1 ready")
        let model = RuneAppViewModel(state: state)
        model.isDetailPaneVisible = true
        var snapshots: [RuneRootLayoutSnapshot] = []
        let host = NSHostingController(rootView: RuneRootView(
            viewModel: model,
            onLayoutSnapshotChange: { snapshots.append($0) },
            debugDisableBootstrap: true,
            podInspectorPresentation: .window,
            shellVariant: .appKitSplitView,
            initialSidebarWidthOverride: 220
        ).frame(width: 1400, height: 900))
        let owner = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        owner.contentViewController = host
        owner.makeKeyAndOrderFront(nil)
        defer {
            model.isLogTailModeEnabled = false
            owner.orderOut(nil)
            owner.contentViewController = nil
            owner.contentView = nil
            for window in inspectorWindows { window.close() }
        }
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.isEmpty, "Initial row selection must not open a window without a user action.")
        let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first)
        let coordinator = try XCTUnwrap(table.delegate as? AppKitPodTableView.Coordinator)
        XCTAssertNotNil(table.action)
        let viewport = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertGreaterThan(viewport.bounds.width, 900, "Pods must use the space previously occupied by the right inspector.")
        XCTAssertNil(snapshots.last?.detailMinX)

        coordinator.activatePod(at: 0)
        try await settle(owner)
        let detail = try XCTUnwrap(inspectorWindows.first)
        XCTAssertTrue(detail !== owner)
        XCTAssertNil(detail.sheetParent, "The Pod window must allow continued use of the list.")
        XCTAssertTrue(detail.styleMask.contains(.resizable))
        XCTAssertEqual(detail.level, .normal)
        XCTAssertGreaterThan(detail.frame.width, 1200)
        XCTAssertGreaterThan(detail.frame.height, 800)
        XCTAssertTrue(detail.title.contains(first.name))
        XCTAssertEqual(inspectorWindows.count, 1)
        // With no cluster configured, an initial detail fetch legitimately clears
        // the warm fixture. Publish the next snapshot after that fetch completes.
        state.setPodLogs("seq=1 ready")
        try await settle(owner)
        try savePreview(owner, name: "pod-list")
        try savePreview(detail, name: "pod-details")
        XCTAssertEqual(state.podLogs, "seq=1 ready")
        let initialLogView = try XCTUnwrap(logView(in: detail))
        XCTAssertTrue(initialLogView.string.contains("seq=1 ready"))
        XCTAssertTrue(model.isLogTailModeEnabled, "Opening a Pod must show live logs without requiring a Tail option.")
        let detailContent = try XCTUnwrap(detail.contentView)
        XCTAssertEqual(model.selectedLogPreset, .recentMinutes)
        XCTAssertEqual(model.selectedLogPreset.filter, .lastMinutes(7))
        let minutesField = try XCTUnwrap(descendants(detailContent).compactMap { $0 as? NSTextField }.first {
            $0.isEditable
        })
        XCTAssertEqual(minutesField.stringValue, "7")
        XCTAssertTrue(detail.makeFirstResponder(minutesField))
        minutesField.selectText(nil)
        let editor = try XCTUnwrap(minutesField.currentEditor() as? NSTextView)
        editor.insertText("3", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        detail.makeFirstResponder(nil)
        try await settle(owner)
        XCTAssertEqual(model.podLogWindowMinutes, 3)
        XCTAssertEqual(minutesField.stringValue, "3")
        XCTAssertTrue(descendants(detailContent).compactMap { $0 as? NSPopUpButton }.isEmpty,
                      "Container and advanced filter menus must stay hidden in the Pod log window.")
        let logViewport = try XCTUnwrap(initialLogView.enclosingScrollView)
        XCTAssertGreaterThan(logViewport.bounds.height, detailContent.bounds.height * 0.85,
                             "Logs must occupy most of the window below the top tabs.")
        XCTAssertGreaterThan(logViewport.bounds.width, detailContent.bounds.width * 0.94)

        state.setPodLogs("seq=1 ready\nseq=2 newest")
        try await settle(owner)
        XCTAssertTrue(logView(in: detail) === initialLogView, "Log updates must retain the viewer and its search/scroll state.")
        XCTAssertTrue(try XCTUnwrap(logView(in: detail)).string.contains("seq=2 newest"))
        try savePreview(owner, name: "pod-list")
        try savePreview(detail, name: "pod-details")

        coordinator.activatePod(at: 1)
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.first === detail)
        XCTAssertEqual(inspectorWindows.count, 1)
        XCTAssertTrue(detail.title.contains(second.name))
        XCTAssertEqual(state.selectedPod?.id, second.id)

        detail.performClose(nil)
        try await settle(owner)
        XCTAssertFalse(model.isLogTailModeEnabled, "Closing the log window must stop its automatic polling.")
        state.setPodLogs("seq=3 while closed")
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.isEmpty, "Background updates must not reopen a dismissed window.")
        coordinator.activatePod(at: 1)
        try await settle(owner)
        let reopened = try XCTUnwrap(inspectorWindows.first)
        XCTAssertTrue(reopened.title.contains(second.name), "Clicking the already-selected row must reopen its window.")
        XCTAssertTrue(try XCTUnwrap(logView(in: reopened)).string.contains("seq=3 while closed"))

        coordinator.parent.onOpenYAML(first)
        try await settle(owner)
        state.setResourceYAML("kind: Pod\nmetadata:\n  name: payment-api-a\n")
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.first === reopened)
        XCTAssertTrue(reopened.title.contains(first.name))
        XCTAssertTrue(descendants(try XCTUnwrap(reopened.contentView))
            .compactMap { $0 as? NSTextView }.contains { $0.string.contains("kind: Pod") })

        coordinator.parent.onOpenNode?(first)
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.isEmpty)
        XCTAssertEqual(state.selectedWorkloadKind, .node)
        model.navigateBack()
        try await settle(owner)
        XCTAssertEqual(state.selectedWorkloadKind, .pod)
        XCTAssertEqual(state.selectedPod?.id, first.id)
        XCTAssertTrue(inspectorWindows.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first?.enclosingScrollView).bounds.width, 900)
        coordinator.activatePod(at: 0)
        try await settle(owner)
        XCTAssertEqual(inspectorWindows.count, 1)
        state.setPodLogs("seq=4 back to logs")
        try await settle(owner)
        XCTAssertTrue(try XCTUnwrap(logView(in: XCTUnwrap(inspectorWindows.first))).string.contains("seq=4 back to logs"),
                      "Clicking a Pod after viewing YAML must return to Logs.")
        owner.performClose(nil)
        try await settle(owner)
        XCTAssertTrue(inspectorWindows.isEmpty, "Closing the owning list must not leave an orphan inspector window.")
    }

    private var inspectorWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue == "rune.pod-inspector-window" && $0.isVisible }
    }

    private func logView(in window: NSWindow) -> NSTextView? {
        window.contentView.flatMap {
            descendants($0).compactMap { $0 as? NSTextView }.first { !$0.isFieldEditor }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<15 {
            window.contentView?.layoutSubtreeIfNeeded()
            for inspector in inspectorWindows { inspector.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func savePreview(_ window: NSWindow, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["RUNE_POD_INSPECTOR_PREVIEW_DIR"],
              let view = window.contentView else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: url.appendingPathComponent("\(name).png"))
    }
}
