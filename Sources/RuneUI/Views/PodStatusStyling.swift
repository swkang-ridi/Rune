import AppKit
import SwiftUI

enum RunePodTableStyle {
    static var font: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
}

enum RunePodStatusTone {
    case running, waiting, starting, terminating, failure, finished, unknown

    init(status: String) {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("init:") {
            let value = String(normalized.dropFirst(5))
            let reason = Self(status: value)
            if case .failure = reason { self = .failure }
            else { self = value.hasPrefix("exitcode:") || value.hasPrefix("signal:") ? .failure : .starting }
            return
        }
        switch normalized {
        case "running", "ready": self = .running
        case "pending", "containercreating": self = .waiting
        case "podinitializing", "initialized": self = .starting
        case "terminating": self = .terminating
        case "failed", "error", "crashloopbackoff", "imagepullbackoff", "errimagepull",
             "createcontainerconfigerror", "createcontainererror", "runcontainererror", "invalidimagename", "oomkilled",
             "evicted", "noready", "containerstatusunknown":
            self = .failure
        case "succeeded", "completed": self = .finished
        default: self = .unknown
        }
    }

    var nativeColor: NSColor {
        switch self {
        case .running: return .systemCyan
        case .waiting: return .systemOrange
        case .starting: return .systemBlue
        case .terminating: return .systemPurple
        case .failure: return .systemRed
        case .finished, .unknown: return .secondaryLabelColor
        }
    }

    func color(in palette: RuneThemePalette?) -> Color {
        switch self {
        case .running: return palette?.accent ?? Color(nsColor: RuneThemeContrast.nativeInk(.systemCyan))
        case .waiting: return RuneSemanticColorRole.warning.color(in: palette)
        case .starting: return RuneSemanticColorRole.info.color(in: palette)
        case .terminating:
            if let palette {
                return Color(nsColor: RuneThemeContrast.readable(.systemPurple, over: [NSColor(palette.panel)]))
            }
            return Color(nsColor: RuneThemeContrast.nativeInk(.systemPurple))
        case .failure: return RuneSemanticColorRole.danger.color(in: palette)
        case .finished, .unknown: return palette?.secondaryText ?? Color.secondary
        }
    }
}
