import RuneCore
import RuneKube

/// Keep only the newest event per Pod during a short UI flush or an in-flight list read.
struct LivePodWatchBatch {
    private(set) var events: [String: KubernetesResourceWatchEvent] = [:]

    mutating func append(_ event: KubernetesResourceWatchEvent, namespace: String) -> Bool {
        guard [.added, .modified, .deleted].contains(event.type),
              let name = event.resourceName, !name.isEmpty,
              event.resourceNamespace == namespace,
              event.type == .deleted || event.pod != nil else { return false }
        events["\(namespace)/\(name)"] = event
        return true
    }

    func applying(to pods: [PodSummary]) -> [PodSummary] {
        var remaining = events
        var result = pods.compactMap { current -> PodSummary? in
            guard let event = remaining.removeValue(forKey: current.id) else { return current }
            guard event.type != .deleted, let pod = event.pod else { return nil }
            return pod.updatingResourceUsage(cpu: current.cpuUsage, memory: current.memoryUsage)
        }
        result += remaining.values.compactMap { event in
            event.type == .deleted ? nil : event.pod
        }.sorted { $0.id < $1.id }
        return result
    }
}
