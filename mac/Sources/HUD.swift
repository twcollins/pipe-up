import AppKit

/// A small click-through pill shown just under the menu bar. It never takes
/// focus and floats over full-screen apps (Zoom, Teams, Meet).
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let box = NSView()
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0

        box.wantsLayer = true
        box.layer?.cornerRadius = 20
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        panel.contentView = box
    }

    /// Show a message. `duration` nil = stay until `hide()`.
    func show(_ text: String, color: NSColor, duration: TimeInterval? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        box.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor

        let width = ceil(label.intrinsicContentSize.width) + 44
        let height: CGFloat = 40
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.midX - width / 2, y: vf.maxY - height - 10, width: width, height: height), display: true)

        if !isVisible {
            isVisible = true
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
        }
        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    func hide() {
        hideWork?.cancel()
        guard isVisible else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
        })
    }
}
