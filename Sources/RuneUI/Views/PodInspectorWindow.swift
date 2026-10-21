import AppKit
import SwiftUI

enum RunePodInspectorPresentation {
    case tabbed
    case window
    case docked
}

/// Hosts the existing inspector in a reusable, independently resizable window.
struct PodInspectorWindow: NSViewRepresentable {
    @Binding var isPresented: Bool
    let presentationID: UUID?
    let title: String
    let content: AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ anchor: NSView, context: Context) {
        context.coordinator.update(parent: self, anchor: anchor)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) var window: NSWindow?
        private var host: NSHostingController<AnyView>?
        private var parent: PodInspectorWindow?
        private var lastPresentationID: UUID?
        private var isClosingProgrammatically = false
        private var ownerCloseObserver: NSObjectProtocol?

        func update(parent: PodInspectorWindow, anchor: NSView) {
            self.parent = parent
            guard parent.isPresented else {
                close()
                return
            }
            let needsPresentation = window == nil || lastPresentationID != parent.presentationID
            if window == nil {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable],
                    backing: .buffered,
                    defer: false
                )
                window.identifier = NSUserInterfaceItemIdentifier("rune.pod-inspector-window")
                window.isReleasedWhenClosed = false
                window.contentMinSize = NSSize(width: 720, height: 500)
                window.delegate = self
                let host = NSHostingController(rootView: parent.content)
                host.sizingOptions = []
                window.contentViewController = host
                window.setContentSize(NSSize(width: 1280, height: 860))
                self.host = host
                self.window = window
                if let owner = anchor.window {
                    ownerCloseObserver = NotificationCenter.default.addObserver(
                        forName: NSWindow.willCloseNotification, object: owner, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.close()
                            self?.parent?.isPresented = false
                        }
                    }
                    var frame = window.frame
                    frame.origin = NSPoint(x: owner.frame.midX - frame.width / 2,
                                           y: owner.frame.midY - frame.height / 2)
                    window.setFrame(window.constrainFrameRect(frame, to: owner.screen), display: false)
                } else {
                    window.center()
                }
            } else {
                host?.rootView = parent.content
            }
            window?.title = parent.title
            if needsPresentation {
                lastPresentationID = parent.presentationID
                window?.deminiaturize(nil)
                window?.makeKeyAndOrderFront(nil)
            }
        }

        func close() {
            removeOwnerObserver()
            isClosingProgrammatically = true
            window?.close()
            window = nil
            host = nil
            lastPresentationID = nil
            isClosingProgrammatically = false
        }

        func windowWillClose(_ notification: Notification) {
            guard !isClosingProgrammatically else { return }
            removeOwnerObserver()
            window = nil
            host = nil
            lastPresentationID = nil
            parent?.isPresented = false
        }

        private func removeOwnerObserver() {
            if let ownerCloseObserver {
                NotificationCenter.default.removeObserver(ownerCloseObserver)
                self.ownerCloseObserver = nil
            }
        }
    }
}
