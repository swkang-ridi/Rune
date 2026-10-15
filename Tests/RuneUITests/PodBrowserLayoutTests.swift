import AppKit
import RuneCore
import SwiftUI
import XCTest
@testable import RuneUI

@MainActor
final class PodBrowserLayoutTests: XCTestCase {
    func testBrowserKeepsTableAndInspectorUsableAtCompactAndWideSizes() async throws {
        let defaults = UserDefaults.standard
        let themeKey = RuneSettingsKeys.appearanceTheme
        let originalTheme = defaults.object(forKey: themeKey)
        defer {
            if let originalTheme { defaults.set(originalTheme, forKey: themeKey) }
            else { defaults.removeObject(forKey: themeKey) }
        }

        for (width, theme) in [(CGFloat(1600), "graphiteBlue"), (1600, "daylight"), (980, "graphiteBlue")] {
            defaults.set(theme, forKey: themeKey)
            let pods = fixtures
            let state = RuneAppState()
            let context = KubeContext(name: "rune-demo")
            state.setContexts([context])
            state.selectedContext = context
            state.selectedNamespace = "payments"
            state.selectedSection = .workloads
            state.selectedWorkloadKind = .pod
            state.setPods(pods)
            state.markResourceListsLive([.pods], message: "Synthetic preview data")
            state.selectedPod = pods[0]
            let model = RuneAppViewModel(state: state)
            model.isSidebarVisible = true
            model.isDetailPaneVisible = true

            let host = NSHostingController(rootView: RuneRootView(
                viewModel: model,
                onLayoutSnapshotChange: nil,
                debugDisableBootstrap: true,
                shellVariant: .appKitSplitView,
                initialSidebarWidthOverride: 220,
                initialDetailWidthOverride: width == 980 ? 320 : 440
            ).frame(width: width, height: 900))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            host.view.frame = NSRect(x: 0, y: 0, width: width, height: 900)
            window.makeKeyAndOrderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
            }
            for _ in 0..<10 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }

            let table = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTableView }.first)
            XCTAssertEqual(table.numberOfRows, pods.count)
            let nodeColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "node" })
            let ipColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "podIP" })
            for (row, pod) in model.visiblePods.enumerated() {
                for (column, expected) in [(nodeColumn, pod.nodeName ?? "—"), (ipColumn, pod.podIP ?? "—")] {
                    let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: column, row: row))
                    let text = descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue
                    XCTAssertEqual(text, expected, "\(column.title) must describe the Pod on the same row.")
                }
            }
            XCTAssertGreaterThanOrEqual(table.selectedRow, 0)
            if table.selectedRow >= 0 {
                XCTAssertEqual(model.visiblePods[table.selectedRow].id, model.state.selectedPod?.id)
            }
            let viewport = try XCTUnwrap(table.enclosingScrollView)
            let viewportRect = viewport.convert(viewport.bounds, to: host.view)
            XCTAssertGreaterThan(viewportRect.width, 300)
            XCTAssertGreaterThan(viewportRect.height, 350)
            XCTAssertGreaterThanOrEqual(viewportRect.minX, 0)
            XCTAssertLessThanOrEqual(viewportRect.maxX, host.view.bounds.maxX)

            if let directory = ProcessInfo.processInfo.environment["RUNE_POD_BROWSER_PREVIEW_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: url.appendingPathComponent("pods-\(Int(width))-\(theme).png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private var fixtures: [PodSummary] {
        (0..<18).map { index in
            PodSummary(
                name: index == 0 ? "payment-api-7c9db8f6d4-rzv22" : "\(index < 10 ? "payment-worker" : "checkout-api")-6b7c9d-\(index)",
                namespace: "payments",
                status: index == 3 ? "CrashLoopBackOff" : index == 8 ? "Pending" : "Running",
                totalRestarts: index == 3 ? 12 : 0,
                ageDescription: "2d",
                cpuUsage: "\(24 + index * 3)m",
                memoryUsage: "\(64 + index * 8)Mi",
                podIP: index == 8 ? nil : index == 12 ? "fd00:10:42::22" : "10.42.0.\(10 + index)",
                hostIP: "10.0.1.24",
                nodeName: index == 8 ? nil : index == 12 ? "worker-eu-west-1a-node-with-a-long-name" : "worker-eu-west-1a",
                qosClass: "Burstable",
                containersReady: index == 3 || index == 8 ? "0/1" : "1/1"
            )
        }
    }
}
