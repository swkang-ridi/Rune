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
            state.setNodes([
                ClusterResourceSummary(kind: .node, name: "worker-eu-west-1a", namespace: nil, primaryText: "Ready", secondaryText: "v1.34", nodePoolName: "payments-pool"),
                ClusterResourceSummary(kind: .node, name: "worker-eu-west-1a-node-with-a-long-name", namespace: nil, primaryText: "Ready", secondaryText: "v1.34", nodePoolName: "checkout-spot-pool")
            ])
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
            XCTAssertEqual(
                table.rect(ofRow: 1).minY - table.rect(ofRow: 0).minY,
                16,
                accuracy: 0.01,
                "The mounted table must keep its configured row spacing instead of a system density preset."
            )
            let nodeColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "node" })
            let ipColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "podIP" })
            let poolColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "nodePool" })
            for (row, pod) in model.visiblePods.enumerated() {
                for (column, expected) in [(nodeColumn, pod.nodeName ?? "—"), (poolColumn, model.nodePoolName(for: pod) ?? "—"), (ipColumn, pod.podIP ?? "—")] {
                    let cell = try XCTUnwrap(table.delegate?.tableView?(table, viewFor: column, row: row))
                    let text = column === nodeColumn
                        ? descendants(cell).compactMap { $0 as? NSButton }.first?.title
                        : descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue
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

            // Node labels can arrive or change without any change to the Pod rows.
            state.setNodes(state.nodes.map { node in
                ClusterResourceSummary(kind: .node, name: node.name, namespace: nil, primaryText: node.primaryText, secondaryText: node.secondaryText, nodePoolName: "updated-pool")
            })
            for _ in 0..<5 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            for (row, pod) in model.visiblePods.enumerated() {
                let cell = try XCTUnwrap(table.view(atColumn: table.tableColumns.firstIndex(of: poolColumn)!, row: row, makeIfNecessary: true))
                XCTAssertEqual(descendants(cell).compactMap { $0 as? NSTextField }.first?.stringValue, pod.nodeName == nil ? "—" : "updated-pool")
            }

            let pendingRow = try XCTUnwrap(model.visiblePods.firstIndex { $0.status == "Pending" })
            let pendingPod = model.visiblePods[pendingRow]
            let rowView = try XCTUnwrap(table.rowView(atRow: pendingRow, makeIfNecessary: true) as? RuneAppKitResourceTableRowView)
            let nameIndex = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == "name" })
            let nameCell = try XCTUnwrap(table.view(atColumn: nameIndex, row: pendingRow, makeIfNecessary: true))
            let nameField = try XCTUnwrap(descendants(nameCell).compactMap { $0 as? NSTextField }.first)
            let pendingInk = RuneThemeColorParser.rgbaHex(try XCTUnwrap(nameField.textColor))
            let pendingFill = RuneThemeColorParser.rgbaHex(rowView.resolvedBackgroundColor)
            state.setPods(state.pods.map { pod in
                pod.id == pendingPod.id
                    ? PodSummary(name: pod.name, namespace: pod.namespace, status: "Running", podIP: pod.podIP, nodeName: pod.nodeName)
                    : pod
            })
            for _ in 0..<5 {
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
            let runningRow = try XCTUnwrap(model.visiblePods.firstIndex { $0.id == pendingPod.id })
            let runningView = try XCTUnwrap(table.rowView(atRow: runningRow, makeIfNecessary: true) as? RuneAppKitResourceTableRowView)
            let runningCell = try XCTUnwrap(table.view(atColumn: nameIndex, row: runningRow, makeIfNecessary: true))
            let runningName = try XCTUnwrap(descendants(runningCell).compactMap { $0 as? NSTextField }.first)
            XCTAssertNotEqual(RuneThemeColorParser.rgbaHex(try XCTUnwrap(runningName.textColor)), pendingInk, "Pod name ink must follow live status changes.")
            XCTAssertEqual(RuneThemeColorParser.rgbaHex(runningView.resolvedBackgroundColor), pendingFill, "Status changes must affect the text without tinting the row background.")
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
                status: index == 3 ? "CrashLoopBackOff" : index == 4 ? "ContainerCreating" : index == 5 ? "PodInitializing" : index == 6 ? "Succeeded" : index == 7 ? "Failed" : index == 8 ? "Pending" : index == 9 ? "Terminating" : "Running",
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
