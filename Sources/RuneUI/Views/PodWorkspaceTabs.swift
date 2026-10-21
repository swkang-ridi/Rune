import AppKit
import RuneCore
import SwiftUI

struct PodWorkspaceTab: Identifiable {
    let pod: PodSummary
    var inspectorTab: PodInspectorTab
    var logContainer: String? = nil

    var id: String { pod.id }
}

/// Native controls keep Pod tabs accessible alongside the AppKit resource table.
struct PodWorkspaceTabBar: NSViewRepresentable {
    @Environment(\.runeThemePalette) private var palette
    let tabs: [PodWorkspaceTab]
    let selectedID: String?
    let onSelect: (String?) -> Void
    let onClose: (String) -> Void

    func makeNSView(context: Context) -> PodWorkspaceTabStrip {
        PodWorkspaceTabStrip()
    }

    func updateNSView(_ strip: PodWorkspaceTabStrip, context: Context) {
        strip.update(tabs: tabs, selectedID: selectedID,
                     accent: NSColor(palette?.accent ?? .accentColor),
                     secondary: NSColor(palette?.secondaryText ?? .secondary),
                     onSelect: onSelect, onClose: onClose)
    }
}

@MainActor
final class PodWorkspaceTabStrip: NSView {
    private let scrollView = NSScrollView()
    private let document = NSView()
    private var groups: [PodWorkspaceTabControl] = []
    private var selectionID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        addSubview(scrollView)
        setAccessibilityElement(false)
        setAccessibilityLabel("Pod tabs")
    }

    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        var x: CGFloat = 0
        for group in groups {
            group.frame = NSRect(x: x, y: 0, width: group.tabWidth, height: bounds.height)
            x += group.tabWidth
        }
        document.frame.size = NSSize(width: max(x, bounds.width), height: bounds.height)
    }

    func update(tabs: [PodWorkspaceTab], selectedID: String?, accent: NSColor, secondary: NSColor,
                onSelect: @escaping (String?) -> Void, onClose: @escaping (String) -> Void) {
        let ids: [String?] = [nil] + tabs.map { Optional($0.id) }
        if groups.map(\.podID) != ids {
            groups.forEach { $0.removeFromSuperview() }
            groups = ids.map { id in
                let control = PodWorkspaceTabControl(podID: id)
                document.addSubview(control)
                return control
            }
        }
        for (index, group) in groups.enumerated() {
            let pod = index == 0 ? nil : tabs[index - 1].pod
            let id = group.podID
            group.update(title: pod?.name ?? "Pods", subtitle: pod.map { "\($0.namespace) / \($0.name)" },
                         isSelected: id == selectedID, accent: accent, secondary: secondary,
                         onSelect: { onSelect(id) },
                         onClose: { if let id { onClose(id) } })
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selectionID != selectedID, let group = groups.first(where: { $0.podID == selectedID }) {
            document.scrollToVisible(group.frame)
        }
        selectionID = selectedID
    }
}

@MainActor
private final class PodWorkspaceTabControl: NSView {
    let podID: String?
    private let selectButton = NSButton()
    private let closeButton = NSButton()
    private let underline = NSView()
    private var onSelect: (() -> Void)?
    private var onClose: (() -> Void)?
    private(set) var tabWidth: CGFloat = 80

    init(podID: String?) {
        self.podID = podID
        super.init(frame: .zero)
        wantsLayer = true
        selectButton.isBordered = false
        selectButton.alignment = .left
        selectButton.imagePosition = .imageLeading
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.setAccessibilityIdentifier(podID.map { "pod-tab:\($0)" } ?? "pod-list-tab")
        (selectButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        if let podID { closeButton.setAccessibilityIdentifier("close-pod-tab:\(podID)") }
        closeButton.isHidden = podID == nil
        underline.wantsLayer = true
        addSubview(selectButton)
        addSubview(closeButton)
        addSubview(underline)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String, subtitle: String?, isSelected: Bool, accent: NSColor, secondary: NSColor,
                onSelect: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onSelect = onSelect
        self.onClose = onClose
        selectButton.title = title
        selectButton.image = NSImage(systemSymbolName: podID == nil ? "list.bullet" : "cube.box", accessibilityDescription: nil)
        selectButton.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        selectButton.contentTintColor = isSelected ? accent : secondary
        selectButton.toolTip = subtitle
        selectButton.setAccessibilityLabel(title)
        closeButton.contentTintColor = isSelected ? accent : secondary
        closeButton.setAccessibilityLabel("Close \(title) tab")
        closeButton.toolTip = "Close tab"
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isSelected ? 0.045 : 0).cgColor
        underline.layer?.backgroundColor = accent.cgColor
        underline.isHidden = !isSelected
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        tabWidth = min(300, ceil(titleWidth) + (podID == nil ? 48 : 76))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        selectButton.frame = NSRect(x: 10, y: 3, width: bounds.width - (podID == nil ? 20 : 38), height: bounds.height - 6)
        closeButton.frame = NSRect(x: bounds.width - 26, y: (bounds.height - 20) / 2, width: 20, height: 20)
        underline.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 2)
    }

    @objc private func selectTab() { onSelect?() }
    @objc private func closeTab() { onClose?() }
}
