import AppKit
import Combine
import RuneCore
import RuneFakeK8sSupport
import RuneStore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class LiveLogRefreshTests: XCTestCase {
    func testPodLogContainerSelectionStartsWithMainAndCanReadInitOrAll() async throws {
        let defaults = UserDefaults.standard
        let key = RuneSettingsKeys.logsRecentWindowMinutes
        let saved = defaults.object(forKey: key)
        defaults.runeRecentLogWindowMinutes = 5
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let pod = PodSummary(name: "ember-gate-75c9f746b8-kq2wm", namespace: "alpha-zone", status: "Running",
                             containerNamesLine: "gate", initContainerNamesLine: "metrics")
        let target = "/api/v1/namespaces/alpha-zone/pods/\(pod.name)/log?sinceSeconds=300&container="
        let server = try await RuneFakeK8sRESTServer.start(fixture: RuneFakeK8sFixture(
            logResponseSequences: [
                target + "gate": ["spark scheduler ready\n"],
                target + "metrics": ["download completed\n"]
            ]
        ))
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        model.state.setSelectedPod(pod)
        model.preparePodLogWindow(for: pod)
        XCTAssertEqual(model.selectedLogContainer, "gate")
        model.isLogTailModeEnabled = true
        try await waitUntil { !model.state.isLoadingLogs && model.state.podLogs.contains("spark scheduler ready") }
        XCTAssertFalse(model.state.podLogs.contains("download completed"))
        XCTAssertTrue(logRequests(server, pod: pod).allSatisfy { $0.contains("container=gate") })

        model.selectedLogContainer = "metrics"
        try await waitUntil { !model.state.isLoadingLogs && model.state.podLogs.contains("download completed") }
        XCTAssertFalse(model.state.podLogs.contains("spark scheduler ready"))
        XCTAssertTrue(try XCTUnwrap(logRequests(server, pod: pod).last).contains("container=metrics"))
        model.preparePodLogWindow()
        XCTAssertEqual(model.selectedLogContainer, "metrics", "Reappearing views must retain the chosen init container.")

        model.selectedLogContainer = ""
        try await waitUntil {
            !model.state.isLoadingLogs && model.state.podLogs.contains("[gate]")
                && model.state.podLogs.contains("[metrics]")
        }
        model.preparePodLogWindow(for: pod, container: "")
        XCTAssertEqual(model.selectedLogContainer, "", "An explicit All containers selection must remain selected.")
        model.preparePodLogWindow(for: pod, container: "removed-container")
        XCTAssertEqual(model.selectedLogContainer, "gate")
    }

    func testRecentMinuteWindowReplacesExpiredLinesAndReloadsWhenMinutesChange() async throws {
        let defaults = UserDefaults.standard
        let key = RuneSettingsKeys.logsRecentWindowMinutes
        let saved = defaults.object(forKey: key)
        defaults.runeRecentLogWindowMinutes = 5
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let pod = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        let target = "/api/v1/namespaces/alpha-zone/pods/\(pod.name)/log?sinceSeconds=300&container=lens"
        let server = try await RuneFakeK8sRESTServer.start(fixture: RuneFakeK8sFixture(
            logResponseSequences: [target: ["leaves-window-soon\ncurrent-line\n", "current-line\nnewest-line\n"]]
        ))
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        model.state.setSelectedPod(pod)
        model.includePreviousLogs = true
        model.preparePodLogWindow()
        XCTAssertEqual(model.selectedLogPreset, .recentMinutes)
        XCTAssertEqual(model.selectedLogPreset.filter, .lastMinutes(5))
        XCTAssertFalse(model.includePreviousLogs)
        model.isLogTailModeEnabled = true
        try await waitUntil { model.state.podLogs.contains("leaves-window-soon") }
        try await waitUntil { model.state.podLogs.contains("newest-line") }
        XCTAssertFalse(model.state.podLogs.contains("leaves-window-soon"), "Rows outside the current time window must not accumulate.")
        XCTAssertTrue(logRequests(server, pod: pod).allSatisfy {
            $0.contains("sinceSeconds=300") && !$0.contains("tailLines=") && !$0.contains("previous=true")
        })

        model.podLogWindowMinutes = 12
        try await waitUntil { self.logRequests(server, pod: pod).contains { $0.contains("sinceSeconds=720") } }
        XCTAssertEqual(model.selectedLogPreset.filter, .lastMinutes(12))
        XCTAssertEqual(defaults.runeRecentLogWindowMinutes, 12)
    }

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

    func testTailKeepsCompleteActiveLogsAndDoesNotPublishIdenticalReads() async throws {
        let pod = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        let target = "/api/v1/namespaces/alpha-zone/pods/\(pod.name)/log?tailLines=200&container=lens"
        let logs = "first-full-log-line\n\(String(repeating: "synthetic payload\n", count: 70_000))last-full-log-line\n"
        let fixture = RuneFakeK8sFixture(
            delayedResponseTargets: [target: 450_000_000],
            logResponseSequences: [target: [logs, logs]]
        )
        let server = try await RuneFakeK8sRESTServer.start(fixture: fixture)
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer {
            model.isLogTailModeEnabled = false
            try? FileManager.default.removeItem(at: configURL)
        }
        model.state.setSelectedPod(pod)
        model.commitPodLogFetch(logs, contextName: model.state.selectedContext!.name,
                               namespace: pod.namespace, podName: pod.name)
        let initialDocument = model.state.podLogs
        let initialFetchTime = try XCTUnwrap(model.state.lastLogUpdatedAt)
        var publishedDocuments: [String] = []
        let subscription = model.state.$podLogs.dropFirst().sink { publishedDocuments.append($0) }
        defer { subscription.cancel() }

        model.isLogTailModeEnabled = true
        try await waitUntil { model.state.isLoadingLogs && !self.logRequests(server, pod: pod).isEmpty }
        XCTAssertEqual(model.state.podLogs, initialDocument, "Do not replay the truncated warm cache before a background read.")
        try await waitUntil {
            self.logRequests(server, pod: pod).count >= 2 && !model.state.isLoadingLogs
        }
        XCTAssertGreaterThan(try XCTUnwrap(model.state.lastLogUpdatedAt), initialFetchTime)
        XCTAssertTrue(publishedDocuments.isEmpty, "Identical responses should leave the active log document untouched.")
        XCTAssertEqual(model.state.podLogs, initialDocument)
    }

    func testInspectorRefreshKeepsCompleteLogsInsteadOfReplayingTruncatedCache() async throws {
        let pod = PodSummary(name: "orbit-lens-6f58d7d89b-hx9q2", namespace: "alpha-zone", status: "Running", containerNamesLine: "lens")
        let target = "/api/v1/namespaces/alpha-zone/pods/\(pod.name)/log?tailLines=200&container=lens"
        let logs = "first-full-log-line\n\(String(repeating: "synthetic payload\n", count: 70_000))last-full-log-line\n"
        let server = try await RuneFakeK8sRESTServer.start(fixture: RuneFakeK8sFixture(
            delayedResponseTargets: [target: 400_000_000], logResponseSequences: [target: [logs]]
        ))
        defer { server.stop() }
        let (model, configURL) = try makeModel(server: server)
        defer { try? FileManager.default.removeItem(at: configURL) }
        model.state.setSelectedPod(pod)
        model.commitPodLogFetch(logs, contextName: model.state.selectedContext!.name,
                               namespace: pod.namespace, podName: pod.name)
        let initialDocument = model.state.podLogs
        XCTAssertTrue(model.state.resourceYAML.isEmpty)
        XCTAssertTrue(model.state.resourceDescribe.isEmpty)
        var publishedDocuments: [String] = []
        let subscription = model.state.$podLogs.dropFirst().sink { publishedDocuments.append($0) }
        defer { subscription.cancel() }

        model.refreshResourceInspectorOnly()
        try await waitUntil { model.state.isLoadingLogs }
        XCTAssertEqual(model.state.podLogs, initialDocument)
        try await waitUntil { !model.state.isLoadingResourceDetails && !model.state.isLoadingLogs }
        XCTAssertTrue(publishedDocuments.isEmpty, "Background inspector refresh must not shrink the current log buffer to its bounded cache.")
        XCTAssertEqual(model.state.podLogs, initialDocument)
    }

    func testNativeLogAppendOnlyEditsNewCharactersAndKeepsSelectionAndANSIColor() async throws {
        let initialText = "\u{1B}[31m" + (0..<300).map { "line-\($0) 로그 🔎" }.joined(separator: "\n")
        let model = LiveLogViewportModel(text: initialText)
        model.followsLatest = false
        let host = NSHostingController(rootView: LiveLogViewportHarness(model: model).frame(width: 760, height: 420))
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
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        let storage = try XCTUnwrap(textView.textStorage)
        let initialLength = storage.length
        let initialColor = storage.attribute(.foregroundColor, at: initialLength - 1, effectiveRange: nil) as? NSColor
        let selection = NSRange(location: 7, length: 8)
        textView.setSelectedRange(selection)
        let edits = LiveLogCharacterEditRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: .main
        ) { notification in
            guard let changedStorage = notification.object as? NSTextStorage,
                  changedStorage.editedMask.contains(.editedCharacters) else { return }
            let range = changedStorage.editedRange
            MainActor.assumeIsolated { edits.ranges.append(range) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.update(text: initialText + "\nnewest 로그 ✅")
        try await settle(window)
        XCTAssertTrue(logScrollView(in: host.view) === scroll)
        XCTAssertEqual(textView.string, ResourceLogANSIFormatter.plainText(from: model.text))
        XCTAssertEqual(textView.selectedRange(), selection)
        XCTAssertFalse(edits.ranges.isEmpty)
        XCTAssertTrue(edits.ranges.allSatisfy { $0.location >= initialLength }, "An append must not replace existing native characters.")
        XCTAssertEqual(storage.attribute(.foregroundColor, at: storage.length - 1, effectiveRange: nil) as? NSColor, initialColor)
        XCTAssertLessThan(scroll.contentView.bounds.minY, 40, "Appending while paused must keep the viewport in place.")
    }

    func testLargeRollingTailKeepsIndexedViewportMountedAcrossSnapshots() async throws {
        let payload = String(repeating: " synthetic wide payload", count: 140)
        func snapshot(_ offset: Int) -> String {
            (offset..<(150 + offset)).map { "line-\($0)\(payload)" }.joined(separator: "\n")
        }
        let model = LiveLogViewportModel(text: snapshot(0))
        let host = NSHostingController(rootView: LiveLogPaneHarness(model: model).frame(width: 760, height: 420))
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
        let originalScroll = try XCTUnwrap(logScrollView(in: host.view))
        let originalDocument = try XCTUnwrap(originalScroll.documentView)

        for offset in 1...3 {
            model.text = snapshot(offset)
            for _ in 0..<12 {
                window.contentView?.layoutSubtreeIfNeeded()
                XCTAssertTrue(logScrollView(in: host.view) === originalScroll,
                              "A rolling snapshot must keep the indexed output visible while its replacement index is pending.")
                XCTAssertTrue(originalScroll.documentView === originalDocument)
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        model.resetID = "another-pod"
        model.text = "different-pod\n" + snapshot(10)
        try await settle(window)
        XCTAssertFalse(logScrollView(in: host.view) === originalScroll, "Another Pod must receive its own viewport.")
    }

    func testRegularLogsFollowLatestAndPreserveTheViewerDuringRefresh() async throws {
        try await verifyLogViewport(large: false)
    }

    func testLargeLogsFollowLatestAndResumeAfterPause() async throws {
        try await verifyLogViewport(large: true)
    }

    func testLargeTailKeepsVisibleGlyphsWhenIndexArrivesAfterGrowingAndShrinkingSnapshots() async throws {
        let payload = String(repeating: " synthetic log payload", count: 40)
        func snapshot(_ count: Int) -> String {
            (0..<count).map { "line-\($0)\(payload)" }.joined(separator: "\n")
        }
        let model = LiveLogViewportModel(text: snapshot(800))
        let host = NSHostingController(rootView: LiveLogViewportHarness(model: model)
            .frame(width: 760, height: 420).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.contentView = nil
        }
        try await settle(window)
        let scroll = try XCTUnwrap(logScrollView(in: host.view))
        try assertVisibleLogGlyphs(in: scroll)

        for count in [1800, 400, 2200, 500] {
            // Network text arrives first; the previous index remains mounted until
            // the asynchronous search/index worker finishes.
            model.text = snapshot(count)
            try await settle(window)
            // Reading earlier lines while a tail jump is pending must not leave
            // the measured viewport empty behind the programmatic target.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window)
            try assertVisibleLogGlyphs(in: scroll)
            model.result = ResourceLogSearchResult.makeForInspector(text: model.text, query: "")
            try await settle(window)
            let current = try XCTUnwrap(logScrollView(in: host.view))
            XCTAssertTrue(current === scroll)
            assertAtEnd(current)
            try assertVisibleLogGlyphs(in: current)
        }
    }

    private func assertVisibleLogGlyphs(in scroll: NSScrollView, file: StaticString = #filePath, line: UInt = #line) throws {
        scroll.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds), file: file, line: line)
        scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
        var brightPixels = 0
        // Sample only the center of the output, excluding borders and scrollbars.
        for y in stride(from: bitmap.pixelsHigh / 4, to: bitmap.pixelsHigh * 3 / 4, by: 2) {
            for x in stride(from: 20, to: bitmap.pixelsWide * 2 / 3, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent * 0.2126 + color.greenComponent * 0.7152 + color.blueComponent * 0.0722 > 0.55 {
                    brightPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(brightPixels, 100, "The log viewport must contain visible text after refresh, not just an empty scroll view.", file: file, line: line)
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
private final class LiveLogCharacterEditRecorder {
    var ranges: [NSRange] = []
}

@MainActor
private final class LiveLogViewportModel: ObservableObject {
    @Published var text: String
    @Published var result: ResourceLogSearchResult
    @Published var isLoading = false
    @Published var followsLatest = true
    @Published var resetID = "live-logs"

    init(text: String) {
        self.text = text
        result = ResourceLogSearchResult.makeForInspector(text: text, query: "")
    }

    func update(text: String) {
        self.text = text
        result = ResourceLogSearchResult.makeForInspector(text: text, query: "")
    }
}

private struct LiveLogPaneHarness: View {
    @ObservedObject var model: LiveLogViewportModel

    var body: some View {
        PodLogsInspectorPane(
            selectedLogPreset: .constant(.recentLines), includePreviousLogs: .constant(false),
            selectedContainer: .constant(""), isTailModeEnabled: $model.followsLatest,
            isStreamPaused: .constant(false), isLoadingLogs: model.isLoading, isLoadingResources: false,
            errorMessage: nil, statusText: "", showsControls: false, containerOptions: [],
            logText: model.text, readOnlyResetID: model.resetID,
            onReload: {}, onSave: {}, onSaveVisibleZip: { _ in }, onSaveFullZip: {},
            onSaveAllPodsZip: {}, onCopySelection: {}, onCopyAll: {}, onToggleStreamPause: {}
        )
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
