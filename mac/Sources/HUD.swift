import AppKit

/// A small pill shown just under the menu bar. It never takes focus and
/// floats over full-screen apps (Zoom, Teams, Meet). Drag it to move it
/// (the position is remembered); hover and click × to dismiss it.
final class HUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let box = PillView()
    private let closeButton = NSButton()
    private var hideWork: DispatchWorkItem?
    private(set) var isVisible = false

    /// Called when the user clicks × (not when the pill hides on its own).
    var onDismiss: (() -> Void)?

    private let height: CGFloat = 40
    private let offsetKey = "hudOffset"   // [dx, dy] of the pill's top-centre from the screen's top-centre

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.alphaValue = 0

        box.wantsLayer = true
        box.layer?.cornerRadius = height / 2
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(label)

        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")
        closeButton.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        closeButton.toolTip = "Dismiss"
        closeButton.target = self
        closeButton.action = #selector(dismissClicked)
        closeButton.alphaValue = 0
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(closeButton)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            closeButton.heightAnchor.constraint(equalToConstant: 20),
        ])
        panel.contentView = box

        box.onHover = { [weak self] inside in
            NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self?.closeButton.animator().alphaValue = inside ? 1 : 0 }
        }
        box.onDragEnd = { [weak self] in self?.saveOffset() }
        box.onDoubleClick = { [weak self] in self?.resetPosition() }
    }

    /// Show a message. `duration` nil = stay until `hide()`.
    func show(_ text: String, color: NSColor, duration: TimeInterval? = nil) {
        hideWork?.cancel()
        label.stringValue = text
        box.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor

        // Room for the text plus the × on the right (kept symmetric so the text stays centred).
        let width = ceil(label.intrinsicContentSize.width) + 44 + 48
        if isVisible {
            // Keep the pill where it is (the user may have just dragged it); only resize around its centre.
            var f = panel.frame
            f.origin.x = f.midX - width / 2
            f.size.width = width
            panel.setFrame(clamped(f, to: panel.screen ?? currentScreen()), display: true)
        } else {
            panel.setFrame(frame(width: width, on: currentScreen()), display: true)
            isVisible = true
            closeButton.alphaValue = box.isMouseInside ? 1 : 0
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

    /// Put the pill back at its default spot, centred under the menu bar.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: offsetKey)
        if isVisible {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.2
                panel.animator().setFrame(frame(width: panel.frame.width, on: panel.screen ?? currentScreen()), display: true)
            }
        }
    }

    @objc private func dismissClicked() {
        hide()
        onDismiss?()
    }

    // MARK: Positioning

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var savedOffset: CGPoint? {
        guard let a = UserDefaults.standard.array(forKey: offsetKey) as? [Double], a.count == 2 else { return nil }
        return CGPoint(x: a[0], y: a[1])
    }

    private func frame(width: CGFloat, on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let o = savedOffset ?? CGPoint(x: 0, y: -10)
        let f = NSRect(x: vf.midX + o.x - width / 2, y: vf.maxY + o.y - height, width: width, height: height)
        return clamped(f, to: screen)
    }

    private func clamped(_ f: NSRect, to screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        var r = f
        r.origin.x = min(max(r.origin.x, vf.minX), vf.maxX - r.width)
        r.origin.y = min(max(r.origin.y, vf.minY), vf.maxY - r.height)
        return r
    }

    private func saveOffset() {
        guard let screen = panel.screen else { return }
        let f = clamped(panel.frame, to: screen)
        panel.setFrame(f, display: true)
        let vf = screen.visibleFrame
        UserDefaults.standard.set([Double(f.midX - vf.midX), Double(f.maxY - vf.maxY)], forKey: offsetKey)
    }
}

/// Content view of the pill: drag to move the window, report hover.
private final class PillView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private(set) var isMouseInside = false
    private var dragStart: NSPoint?
    private var originStart: NSPoint?
    private var dragged = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true; onHover?(true) }
    override func mouseExited(with event: NSEvent) { isMouseInside = false; onHover?(false) }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        dragStart = NSEvent.mouseLocation
        originStart = window?.frame.origin
        dragged = false
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let origin = originStart, let window else { return }
        let p = NSEvent.mouseLocation
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        NSCursor.pop()
        dragStart = nil
        if dragged { onDragEnd?() }
    }
}
