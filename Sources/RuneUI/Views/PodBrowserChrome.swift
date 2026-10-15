import RuneCore
import SwiftUI

/// Flat, scrollable navigation shared by the Pod browser and its inspector.
struct RuneBrowserTabBar<Selection: Hashable>: View {
    let options: [(value: Selection, title: String)]
    @Binding var selection: Selection
    let accessibilityLabel: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 18) {
                    ForEach(options, id: \.value) { option in
                        RuneBrowserTab(title: option.title, isSelected: selection == option.value) {
                            selection = option.value
                        }
                        .id(option.value)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .onChange(of: selection) { _, value in
                proxy.scrollTo(value, anchor: .center)
            }
            .onAppear {
                proxy.scrollTo(selection, anchor: .center)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.25)).frame(height: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Scroll horizontally to reveal additional tabs")
    }
}

private struct RuneBrowserTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.runeThemePalette) private var palette

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? (palette?.accent ?? Color.accentColor) : (palette?.secondaryText ?? Color.secondary))
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                        .opacity(isSelected ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct RunePodBrowserHeading: View {
    let context: String
    let namespace: String
    let visibleCount: Int
    let totalCount: Int
    let isLoading: Bool
    @Binding var isLive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "network")
                Text(context)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Text(namespace)
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
            .foregroundStyle(.runeSecondary)
            .help("\(context) / \(namespace)")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 8)
                    liveControl
                }
                VStack(alignment: .leading, spacing: 8) {
                    title
                    liveControl
                }
            }
        }
        .accessibilityIdentifier("pod-browser-heading")
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text("Pods").font(.title2.weight(.semibold))
            Text(visibleCount == totalCount ? "\(totalCount)" : "\(visibleCount) / \(totalCount)")
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(.runeSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel("\(visibleCount) visible of \(totalCount) Pods")
            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel("Loading Pods")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var liveControl: some View {
        Toggle("Auto refresh", isOn: $isLive)
            .toggleStyle(.switch).controlSize(.small)
            .font(.caption).foregroundStyle(.runeSecondary)
            .fixedSize()
            .help("Watch Pod changes and refresh this list automatically.")
            .accessibilityLabel("Automatically refresh Pods")
    }
}

struct RunePodInspectorSummary: View {
    let pod: PodSummary
    @Environment(\.runeThemePalette) private var palette

    private var statusColor: Color {
        switch pod.status.lowercased() {
        case "running", "succeeded", "completed", "ready": return RuneSemanticColorRole.success.color(in: palette)
        case "pending", "terminating", "containercreating": return RuneSemanticColorRole.warning.color(in: palette)
        case "failed", "error", "crashloopbackoff", "imagepullbackoff", "errimagepull", "createcontainerconfigerror":
            return RuneSemanticColorRole.danger.color(in: palette)
        default: return palette?.secondaryText ?? Color.secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(pod.status).foregroundStyle(statusColor)
                Spacer(minLength: 8)
                Label(pod.namespace, systemImage: "square.stack.3d.up")
                    .foregroundStyle(.runeSecondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(pod.namespace)
            }
            .font(.caption.weight(.medium))
            HStack(spacing: 0) {
                metric("Ready", value: pod.containersReady ?? "—")
                Divider().frame(height: 30)
                metric("CPU", value: pod.cpuDisplay)
                Divider().frame(height: 30)
                metric("Memory", value: pod.memoryDisplay)
            }
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.runeSecondary)
            Text(value).font(.system(.callout, design: .monospaced).weight(.medium))
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }
}
