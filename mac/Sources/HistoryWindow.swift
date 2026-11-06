import AppKit

/// Draws stored per-second history over a chosen time range.
final class TimelineView: NSView {
    var store: HistoryStore?
    var range: TimeInterval = 15 * 60
    var onHover: ((String?) -> Void)?

    private let minDb: Float = -70, maxDb: Float = 0
    private var hoverX: CGFloat?
    private let margins = NSEdgeInsets(top: 10, left: 44, bottom: 24, right: 12)

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    private var plotRect: NSRect {
        NSRect(x: margins.left, y: margins.bottom,
               width: max(10, bounds.width - margins.left - margins.right),
               height: max(10, bounds.height - margins.top - margins.bottom))
    }

    private func y(_ db: Float, _ r: NSRect) -> CGFloat {
        let t = (min(max(db, minDb), maxDb) - minDb) / (maxDb - minDb)
        return r.minY + CGFloat(t) * r.height
    }

    private struct Column {
        var energy: Double = 0, n = 0
        var peak: Float = -200
        var speechSum: Double = 0, speechN = 0
        var baseline: Float?, threshold: Float?
        var quiet = false, silent = false
        var level: Float? { n == 0 ? nil : Float(10 * log10(max(energy / Double(n), 1e-14))) }
        var speech: Float? { speechN == 0 ? nil : Float(speechSum / Double(speechN)) }
    }

    private func columns(in r: NSRect, end: TimeInterval) -> [Column] {
        guard let store else { return [] }
        let count = max(1, Int(r.width))
        var cols = [Column](repeating: Column(), count: count)
        let start = end - range
        var i = store.firstIndex(atOrAfter: start)
        let recs = store.records
        while i < recs.count {
            let rec = recs[i]; i += 1
            if rec.time > end { break }
            let c = min(count - 1, Int((rec.time - start) / range * Double(count)))
            cols[c].energy += pow(10, Double(rec.level) / 10)
            cols[c].n += 1
            cols[c].peak = max(cols[c].peak, rec.peak)
            if let s = rec.speech { cols[c].speechSum += Double(s); cols[c].speechN += 1 }
            if let b = rec.baseline { cols[c].baseline = b }
            if let t = rec.threshold { cols[c].threshold = t }
            if rec.state == .quiet { cols[c].quiet = true }
            if rec.state == .silent { cols[c].silent = true }
        }
        return cols
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = plotRect
        let end = Date().timeIntervalSince1970
        NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]

        // dB grid
        for db in stride(from: Float(-60), through: 0, by: 10) {
            let yy = y(db, r)
            NSColor.separatorColor.withAlphaComponent(db.truncatingRemainder(dividingBy: 20) == 0 ? 0.6 : 0.25).setFill()
            NSRect(x: r.minX, y: yy, width: r.width, height: 0.5).fill()
            if Int(db) % 20 == 0 {
                let s = "\(Int(db)) dB" as NSString
                let sz = s.size(withAttributes: labelAttrs)
                s.draw(at: NSPoint(x: r.minX - sz.width - 6, y: yy - sz.height / 2), withAttributes: labelAttrs)
            }
        }

        // Time axis
        let tick = Self.tickInterval(for: range)
        let fmt = DateFormatter()
        fmt.dateFormat = tick < 60 ? "HH:mm:ss" : "HH:mm"
        var t = (ceil((end - range) / tick)) * tick
        while t <= end {
            let x = r.minX + CGFloat((t - (end - range)) / range) * r.width
            NSColor.separatorColor.withAlphaComponent(0.25).setFill()
            NSRect(x: x, y: r.minY, width: 0.5, height: r.height).fill()
            let s = fmt.string(from: Date(timeIntervalSince1970: t)) as NSString
            let sz = s.size(withAttributes: labelAttrs)
            s.draw(at: NSPoint(x: min(max(x - sz.width / 2, r.minX), r.maxX - sz.width), y: r.minY - sz.height - 5), withAttributes: labelAttrs)
            t += tick
        }

        let cols = columns(in: r, end: end)
        let w = r.width / CGFloat(cols.count)

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()

        // Alert bands
        for (i, c) in cols.enumerated() where c.quiet || c.silent {
            (c.silent ? NSColor.systemRed : NSColor.systemOrange).withAlphaComponent(0.18).setFill()
            NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w + 0.5, height: r.height).fill()
        }
        // Peak (light) and mean level (darker)
        for (i, c) in cols.enumerated() where c.n > 0 {
            let x = r.minX + CGFloat(i) * w
            NSColor.quaternaryLabelColor.withAlphaComponent(0.35).setFill()
            NSRect(x: x, y: r.minY, width: w + 0.5, height: y(c.peak, r) - r.minY).fill()
            if let lv = c.level {
                NSColor.tertiaryLabelColor.withAlphaComponent(0.45).setFill()
                NSRect(x: x, y: r.minY, width: w + 0.5, height: y(lv, r) - r.minY).fill()
            }
        }
        // Lines: speaking, normal, alert line
        func line(_ value: (Column) -> Float?, color: NSColor, width: CGFloat, dash: [CGFloat]?) {
            let p = NSBezierPath(); p.lineWidth = width
            if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
            var drawing = false
            for (i, c) in cols.enumerated() {
                guard let v = value(c) else { drawing = false; continue }
                let pt = NSPoint(x: r.minX + (CGFloat(i) + 0.5) * w, y: y(v, r))
                drawing ? p.line(to: pt) : p.move(to: pt)
                drawing = true
            }
            color.setStroke(); p.stroke()
        }
        line({ $0.threshold }, color: .systemOrange, width: 1, dash: [2, 3])
        line({ $0.baseline }, color: NSColor.labelColor.withAlphaComponent(0.6), width: 1, dash: [5, 4])
        line({ $0.speech }, color: .controlAccentColor, width: 2, dash: nil)

        // Hover
        if let hx = hoverX, hx >= r.minX, hx <= r.maxX {
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            NSRect(x: hx, y: r.minY, width: 1, height: r.height).fill()
            let i = min(cols.count - 1, max(0, Int((hx - r.minX) / w)))
            let c = cols[i]
            let time = end - range + range * Double((hx - r.minX) / r.width)
            let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
            var parts = [tf.string(from: Date(timeIntervalSince1970: time))]
            if let lv = c.level {
                parts.append("level \(Int(lv.rounded())) dB")
                if let s = c.speech { parts.append("speaking \(Int(s.rounded())) dB") }
                if let b = c.baseline { parts.append("normal \(Int(b.rounded())) dB") }
                if c.silent { parts.append("SILENT") } else if c.quiet { parts.append("QUIET") }
            } else {
                parts.append("no data")
            }
            onHover?(parts.joined(separator: " · "))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    static func tickInterval(for range: TimeInterval) -> TimeInterval {
        let options: [TimeInterval] = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800, 21600]
        return options.first { range / $0 <= 7 } ?? 21600
    }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        onHover?(nil)
        needsDisplay = true
    }
}

/// Resizable window around the timeline, with range picker and summary.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: HistoryStore
    private let timeline = TimelineView()
    private let rangeControl: NSSegmentedControl
    private let onTopCheck = NSButton(checkboxWithTitle: "Keep on top", target: nil, action: nil)
    private let summary = NSTextField(labelWithString: "")
    private let hoverLabel = NSTextField(labelWithString: "")
    private var timer: Timer?
    var openDataFolder: (() -> Void)?

    private let ranges: [(String, TimeInterval)] = [
        ("1m", 60), ("5m", 300), ("15m", 900), ("1h", 3600), ("4h", 14400), ("24h", 86400)]

    init(store: HistoryStore) {
        self.store = store
        rangeControl = NSSegmentedControl(labels: ranges.map(\.0), trackingMode: .selectOne, target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 320),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Pipe Up — History"
        window.minSize = NSSize(width: 420, height: 220)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        super.init(window: window)
        window.delegate = self

        let defaults = UserDefaults.standard
        let savedRange = defaults.object(forKey: "historyRange") as? Int ?? 2
        rangeControl.selectedSegment = min(max(savedRange, 0), ranges.count - 1)
        timeline.range = ranges[rangeControl.selectedSegment].1
        rangeControl.target = self
        rangeControl.action = #selector(rangeChanged)

        onTopCheck.target = self
        onTopCheck.action = #selector(toggleOnTop)
        onTopCheck.state = defaults.bool(forKey: "historyOnTop") ? .on : .off
        window.level = onTopCheck.state == .on ? .floating : .normal

        let folderButton = NSButton(title: "Open data folder", target: self, action: #selector(openFolder))
        folderButton.bezelStyle = .rounded
        folderButton.controlSize = .small

        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        hoverLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hoverLabel.textColor = .secondaryLabelColor
        hoverLabel.lineBreakMode = .byTruncatingTail
        timeline.store = store
        timeline.onHover = { [weak self] text in self?.hoverLabel.stringValue = text ?? "" }

        let top = NSStackView(views: [rangeControl, onTopCheck, NSView(), folderButton])
        top.orientation = .horizontal
        top.spacing = 12
        let bottom = NSStackView(views: [summary, NSView(), hoverLabel])
        bottom.orientation = .horizontal
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hoverLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [top, timeline, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [top, timeline, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            timeline.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        timeline.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        window.setFrameAutosaveName("HistoryWindow")
        if !window.setFrameUsingName("HistoryWindow") { window.center() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        if timer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        timeline.needsDisplay = true
        summary.stringValue = summaryText()
    }

    private func summaryText() -> String {
        let start = Date().timeIntervalSince1970 - timeline.range
        let recs = store.records[store.firstIndex(atOrAfter: start)...]
        guard !recs.isEmpty else { return "No data in this range yet" }
        var quietEpisodes = 0, quietSecs = 0, silentSecs = 0
        var speechSum: Double = 0, speechN = 0
        var prev: HistoryRecord.State?
        for r in recs {
            if r.state == .quiet { quietSecs += 1; if prev != .quiet { quietEpisodes += 1 } }
            if r.state == .silent { silentSecs += 1 }
            if let s = r.speech { speechSum += Double(s); speechN += 1 }
            prev = r.state
        }
        var parts = ["Quiet alerts: \(quietEpisodes)"]
        if quietSecs > 0 { parts.append("quiet for \(Self.duration(quietSecs))") }
        if silentSecs > 0 { parts.append("silent for \(Self.duration(silentSecs))") }
        if speechN > 0 {
            parts.append("talking \(Self.duration(speechN))")
            parts.append("avg speaking level \(Int((speechSum / Double(speechN)).rounded())) dB")
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ secs: Int) -> String {
        secs < 60 ? "\(secs)s" : secs < 3600 ? "\(secs / 60)m \(secs % 60)s" : "\(secs / 3600)h \(secs % 3600 / 60)m"
    }

    @objc private func rangeChanged() {
        timeline.range = ranges[rangeControl.selectedSegment].1
        UserDefaults.standard.set(rangeControl.selectedSegment, forKey: "historyRange")
        refresh()
    }

    @objc private func toggleOnTop() {
        let on = onTopCheck.state == .on
        window?.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: "historyOnTop")
    }

    @objc private func openFolder() { openDataFolder?() }
}
