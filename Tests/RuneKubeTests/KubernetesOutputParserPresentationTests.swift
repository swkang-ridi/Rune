import RuneKube
import RuneCore
import XCTest

final class KubernetesOutputParserPresentationTests: XCTestCase {
    func testListAndWatchPodDocumentsShowContainerFailuresAndTerminationImmediately() throws {
        let parser = KubernetesOutputParser()
        let cases: [(String, [String: Any], [String: Any])] = [
            ("Terminating", ["deletionTimestamp": "2026-10-15T00:00:00Z"], ["phase": "Running"]),
            ("ImagePullBackOff", [:], ["phase": "Pending", "containerStatuses": [["state": ["waiting": ["reason": "ImagePullBackOff"]]]]]),
            ("Init:Error", [:], ["phase": "Pending", "initContainerStatuses": [["state": ["terminated": ["reason": "Error", "exitCode": 1]]]]]),
            ("Succeeded", [:], ["phase": "Succeeded", "containerStatuses": [["state": ["terminated": ["reason": "Completed", "exitCode": 0]]]]]),
            ("Evicted", [:], ["phase": "Failed", "reason": "Evicted"])
        ]
        for (expected, extraMetadata, status) in cases {
            var metadata: [String: Any] = ["name": "api", "namespace": "payments"]
            metadata.merge(extraMetadata) { _, value in value }
            let pod: [String: Any] = ["kind": "Pod", "metadata": metadata, "status": status]
            let single = String(decoding: try JSONSerialization.data(withJSONObject: pod), as: UTF8.self)
            let list = String(decoding: try JSONSerialization.data(withJSONObject: ["items": [pod]]), as: UTF8.self)
            XCTAssertEqual(try parser.parseSinglePodJSON(namespace: "payments", from: single).status, expected)
            XCTAssertEqual(try parser.parsePodsListJSON(namespace: "payments", from: list).first?.status, expected)
        }
    }

    func testNodePoolsComeFromProviderLabelsWithStablePrecedence() throws {
        let parser = KubernetesOutputParser()
        let providerKeys = [
            "karpenter.sh/nodepool", "eks.amazonaws.com/nodegroup", "cloud.google.com/gke-nodepool",
            "kubernetes.azure.com/agentpool", "agentpool", "karpenter.sh/provisioner-name",
            "alpha.eksctl.io/nodegroup-name"
        ]
        for key in providerKeys {
            let data = try JSONSerialization.data(withJSONObject: ["items": [[
                "metadata": ["name": "worker-a", "labels": [key: " application-pool "]],
                "status": ["conditions": [["type": "Ready", "status": "True"]]]
            ]]])
            let nodes = try parser.parseNodes(from: String(decoding: data, as: UTF8.self))
            XCTAssertEqual(nodes.first?.nodePoolName, "application-pool", key)
            XCTAssertEqual(nodes.first?.primaryText, "Ready")
        }
        let nodes = try parser.parseNodes(from: #"""
        {"items":[
          {"metadata":{"name":"a","labels":{"karpenter.sh/nodepool":"current","karpenter.sh/provisioner-name":"old"}},"status":{}},
          {"metadata":{"name":"b","labels":{"karpenter.sh/nodepool":"  ","eks.amazonaws.com/nodegroup":"managed"}},"status":{}},
          {"metadata":{"name":"c","labels":{"unrelated":"unknown"}},"status":{}},
          {"metadata":{"name":"d"},"status":{}}
        ]}
        """#)
        XCTAssertEqual(nodes.map(\.nodePoolName), ["current", "managed", nil, nil])
    }

    func testOlderCachedNodeSummariesStillDecodeWithoutNodePool() throws {
        let raw = #"{"kind":"node","name":"worker-a","primaryText":"Ready","secondaryText":"v1.34"}"#
        let node = try JSONDecoder().decode(ClusterResourceSummary.self, from: Data(raw.utf8))
        XCTAssertNil(node.nodePoolName)
    }

    func testConfigMapSummariesUseSpecificPluralizedValueCounts() throws {
        let raw = #"""
        {
          "items": [
            {
              "metadata": { "name": "text-only", "namespace": "sample-namespace" },
              "data": { "setting": "enabled" }
            },
            {
              "metadata": { "name": "mixed-values", "namespace": "sample-namespace" },
              "data": { "first": "one", "second": "two" },
              "binaryData": { "payload": "AA==" }
            }
          ]
        }
        """#

        let summaries = try KubernetesOutputParser().parseConfigMaps(
            namespace: "sample-namespace",
            from: raw
        )

        XCTAssertEqual(summaries.map(\.name), ["mixed-values", "text-only"])
        XCTAssertEqual(summaries[0].primaryText, "3 keys")
        XCTAssertEqual(summaries[0].secondaryText, "2 text values · 1 binary value")
        XCTAssertEqual(summaries[1].primaryText, "1 key")
        XCTAssertEqual(summaries[1].secondaryText, "1 text value · 0 binary values")
    }

    func testGenericSummariesExposeSemanticProgressSelectorsAndPluralization() throws {
        let parser = KubernetesOutputParser()
        let jobs = try parser.parseJobs(
            namespace: "sample-namespace",
            from: #"{"items":[{"metadata":{"name":"batch","namespace":"sample-namespace"},"spec":{"completions":3},"status":{"active":1,"succeeded":2}}]}"#
        )
        let policies = try parser.parseNetworkPolicies(
            namespace: "sample-namespace",
            from: #"{"items":[{"metadata":{"name":"allow-web","namespace":"sample-namespace"},"spec":{"policyTypes":["Ingress"],"podSelector":{"matchLabels":{"app":"sample"}}}}]}"#
        )
        let secrets = try parser.parseSecrets(
            namespace: "sample-namespace",
            from: #"{"items":[{"metadata":{"name":"credentials","namespace":"sample-namespace"},"type":"Opaque","data":{"token":"AA=="}}]}"#
        )

        XCTAssertEqual(jobs.first?.primaryText, "Running (1)")
        XCTAssertEqual(jobs.first?.secondaryText, "2/3 complete")
        XCTAssertEqual(policies.first?.primaryText, "Ingress")
        XCTAssertEqual(policies.first?.secondaryText, "app=sample")
        XCTAssertEqual(secrets.first?.primaryText, "Opaque")
        XCTAssertEqual(secrets.first?.secondaryText, "1 value")
    }

    func testExpressionSelectorsArePresentedAsScopedSelections() throws {
        let parser = KubernetesOutputParser()
        let policies = try parser.parseNetworkPolicies(
            namespace: "sample-namespace",
            from: #"{"items":[{"metadata":{"name":"expression-policy","namespace":"sample-namespace"},"spec":{"policyTypes":["Ingress"],"podSelector":{"matchExpressions":[{"key":"tier","operator":"In","values":["api","web"]}]}}}]}"#
        )
        let statefulSets = try parser.parseStatefulSets(
            namespace: "sample-namespace",
            from: #"{"items":[{"metadata":{"name":"expression-workload","namespace":"sample-namespace"},"spec":{"replicas":2,"selector":{"matchExpressions":[{"key":"deprecated","operator":"DoesNotExist"}]}},"status":{"readyReplicas":1}}]}"#
        )

        XCTAssertEqual(policies.first?.secondaryText, "tier in (api, web)")
        XCTAssertNotEqual(policies.first?.secondaryText, "All pods")
        XCTAssertEqual(statefulSets.first?.secondaryText, "!deprecated")
    }
}
