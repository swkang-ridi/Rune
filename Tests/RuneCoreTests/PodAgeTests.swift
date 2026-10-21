import Foundation
import XCTest
@testable import RuneCore

final class PodAgeTests: XCTestCase {
    func testAgeAdvancesAcrossUnitsWithoutChangingPodDetails() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let pod = PodSummary(name: "pod", namespace: "ns", status: "Running", totalRestarts: 2,
                             ageDescription: "0s", creationDate: created, cpuUsage: "42m", memoryUsage: "96Mi",
                             podIP: "10.42.0.10", nodeName: "node-a", containerNamesLine: "app", labels: ["app": "api"])
        for (elapsed, expected) in [(0, "0s"), (59, "59s"), (60, "1m"), (3599, "59m"),
                                    (3600, "1h"), (86400, "1d"), (31_536_000, "1y")] {
            let updated = pod.updatingAge(reference: created.addingTimeInterval(TimeInterval(elapsed)))
            XCTAssertEqual(updated.ageDescription, expected)
            XCTAssertEqual(updated.id, pod.id)
            XCTAssertEqual(updated.creationDate, pod.creationDate)
            XCTAssertEqual(updated.status, pod.status)
            XCTAssertEqual(updated.totalRestarts, pod.totalRestarts)
            XCTAssertEqual(updated.cpuUsage, pod.cpuUsage)
            XCTAssertEqual(updated.memoryUsage, pod.memoryUsage)
            XCTAssertEqual(updated.nodeName, pod.nodeName)
            XCTAssertEqual(updated.podIP, pod.podIP)
            XCTAssertEqual(updated.labels, pod.labels)
        }
        XCTAssertEqual(pod.updatingAge(reference: created.addingTimeInterval(-5)).ageDescription, "0s")
    }

    func testCreationDateSurvivesMetricsInspectorAndSavedSnapshots() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let pod = PodSummary(name: "pod", namespace: "ns", status: "Running", creationDate: created)
        let metrics = pod.updatingResourceUsage(cpu: "42m", memory: "96Mi")
        let detail = PodSummary(name: "pod", namespace: "ns", status: "Running", nodeName: "node-a")
        let merged = metrics.mergingInspectorDetail(detail)
        XCTAssertEqual(merged.creationDate, created)
        XCTAssertEqual(merged.updatingAge(reference: created.addingTimeInterval(61)).ageDescription, "1m")
        XCTAssertEqual(detail.mergingInspectorDetail(pod).creationDate, created)
        let restored = try JSONDecoder().decode(PodSummary.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(restored, merged)
    }

    func testMissingOrInvalidCreationTimePreservesLegacyAge() throws {
        let data = Data(#"{"name":"legacy","namespace":"ns","status":"Running","totalRestarts":0,"ageDescription":"3m","labels":{}}"#.utf8)
        let legacy = try JSONDecoder().decode(PodSummary.self, from: data)
        XCTAssertNil(legacy.creationDate)
        XCTAssertEqual(legacy.updatingAge(), legacy)
        XCTAssertNil(KubernetesAgeFormatting.creationDate(from: "invalid"))
        XCTAssertNil(KubernetesAgeFormatting.creationDate(from: nil))
        let date = try XCTUnwrap(KubernetesAgeFormatting.creationDate(from: "2026-10-21T10:00:00.500Z"))
        XCTAssertEqual(KubernetesAgeFormatting.describe(creationDate: date, reference: date.addingTimeInterval(60)), "1m")
    }
}
