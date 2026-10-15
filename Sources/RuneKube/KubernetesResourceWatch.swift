import Foundation
import RuneCore

public enum KubernetesResourceWatchEventType: String, Sendable, Equatable {
    case added = "ADDED"
    case modified = "MODIFIED"
    case deleted = "DELETED"
    case bookmark = "BOOKMARK"
    case error = "ERROR"
    case unknown
}

public struct KubernetesResourceWatchEvent: Sendable, Equatable {
    public let type: KubernetesResourceWatchEventType
    public let resourceVersion: String?
    public let errorMessage: String?
    public let errorStatusCode: Int?
    public let resourceName: String?
    public let resourceNamespace: String?
    public let pod: PodSummary?

    public init(
        type: KubernetesResourceWatchEventType,
        resourceVersion: String? = nil,
        errorMessage: String? = nil,
        errorStatusCode: Int? = nil,
        resourceName: String? = nil,
        resourceNamespace: String? = nil,
        pod: PodSummary? = nil
    ) {
        self.type = type
        self.resourceVersion = resourceVersion
        self.errorMessage = errorMessage
        self.errorStatusCode = errorStatusCode
        self.resourceName = resourceName ?? pod?.name
        self.resourceNamespace = resourceNamespace ?? pod?.namespace
        self.pod = pod
    }

    static func decode(line: String) throws -> KubernetesResourceWatchEvent {
        guard let data = line.data(using: .utf8),
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw RuneError.parseError(message: "Kubernetes watch returned an invalid event envelope.")
        }
        let rawType = (envelope["type"] as? String)?.uppercased() ?? ""
        let type = KubernetesResourceWatchEventType(rawValue: rawType) ?? .unknown
        let object = envelope["object"] as? [String: Any]
        let metadata = object?["metadata"] as? [String: Any]
        let statusMessage = object?["message"] as? String
        var pod: PodSummary?
        if object?["kind"] as? String == "Pod",
           object?["status"] is [String: Any],
           let object, let data = try? JSONSerialization.data(withJSONObject: object) {
            pod = try? KubernetesOutputParser().parseSinglePodJSON(
                namespace: metadata?["namespace"] as? String ?? "",
                from: String(decoding: data, as: UTF8.self)
            )
        }
        return KubernetesResourceWatchEvent(
            type: type,
            resourceVersion: metadata?["resourceVersion"] as? String,
            errorMessage: type == .error ? statusMessage ?? "Kubernetes watch reported an error." : nil,
            errorStatusCode: type == .error ? object?["code"] as? Int : nil,
            resourceName: metadata?["name"] as? String,
            resourceNamespace: metadata?["namespace"] as? String,
            pod: pod
        )
    }
}

public struct KubernetesResourceWatchError: LocalizedError, Sendable {
    public let statusCode: Int
    public let message: String
    public var errorDescription: String? { message }

    public init(statusCode: Int, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}
