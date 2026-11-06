import AppKit

/// Draws stored per-second history over a chosen time range.
///
/// Rather than plotting every second (which is spiky), each column summarises
/// a sliding window of your speech levels:
///   light band  = full range (10th–90th percentile)
///   darker band = typical range (middle 50%)
///   solid line  = trend (median)
/// plus your normal level, the alert line, background noise, and shaded
/// periods where your level dropped or the mic went silent.
final class TimelineView: NSView {
    var store: HistoryStore?
    var range: TimeInterval = 15 * 60
    var showRaw = false
    var onHover: ((String?) -> Void)?

    private var minDb: Float = -70, maxDb: Float = 0   // fitted to the data on each draw
    private var hoverX: CGFloat?
    private let margins = NSEdgeInsets(top: 10, left: 44, bottom: 24, right: 12)
    private let columnWidth: CGFloat = 3

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

    struct Column {
        var mid: TimeInterval = 0
        var hasData = false
        var p10: Float?, p25: Float?, p50: Float?, p75: Float?, p90: Float?
        var background: Float?
        var baseline: Float?, threshold: Float?
        var quiet = false, silent = false
        var rawLevel: Float?, rawPeak: Float?
    }

    /// Smoothing window in seconds for a given range.
    /// 1m → 6 s, 5m → 20 s, 15m → 23 s, 1h → 90 s, 24h → 36 min.
    static func window(for range: TimeInterval) -> TimeInterval {
        max(6, min(range / 15, max(range / 40, 20)))
    }

    private func percentile(_ sorted: [Float], _ p: Double) -> Float {
        let idx = p * Double(sorted.count - 1)
        let lo = Int(idx.rounded(.down)), hi = Int(idx.rounded(.up))
        let f = Float(idx - Double(lo))
        return sorted[lo] * (1 - f) + sorted[hi] * f
    }

    func columns(width: CGFloat, end: TimeInterval) -> [Column] {
        guard let store else { return [] }
        let n = max(1, Int(width / columnWidth))
        let start = end - range
        let colDur = range / Double(n)
        let win = Self.window(for: range)
        let recs = store.records
        var cols: [Column] = []
        cols.reserveCapacity(n)

        for c in 0..<n {
            var col = Column()
            let t0 = start + Double(c) * colDur
            let t1 = max(t0 + colDur, t0 + 1)          // at least one second of data
            col.mid = t0 + colDur / 2

            // The column's own slice: state, raw level, normal/alert lines.
            var energy = 0.0, count = 0
            var peak: Float = -200
            var i = store.firstIndex(atOrAfter: t0)
            while i < recs.count, recs[i].time < t1 {
                let r = recs[i]
                col.hasData = true
                energy += pow(10, Double(r.level) / 10); count += 1
                peak = max(peak, r.peak)
                if r.state == .quiet { col.quiet = true }
                if r.state == .silent { col.silent = true }
                if let b = r.baseline { col.baseline = b }
                if let t = r.threshold { col.threshold = t }
                i += 1
            }
            guard col.hasData else { cols.append(col); continue }   // app wasn't running: leave a gap
            col.rawLevel = Float(10 * log10(max(energy / Double(count), 1e-14)))
            col.rawPeak = peak

            // Sliding window: speech distribution and background.
            var speech: [Float] = [], bg: [Float] = []
            var j = store.firstIndex(atOrAfter: col.mid - win / 2)
            while j < recs.count, recs[j].time < col.mid + win / 2 {
                if let s = recs[j].speech { speech.append(s) }
                if let nf = recs[j].noiseFloor { bg.append(nf) }
                j += 1
            }
            if speech.count >= 3 {
                speech.sort()
                col.p10 = percentile(speech, 0.10); col.p25 = percentile(speech, 0.25)
                col.p50 = percentile(speech, 0.50)
                col.p75 = percentile(speech, 0.75); col.p90 = percentile(speech, 0.90)
            }
            if !bg.isEmpty { bg.sort(); col.background = percentile(bg, 0.5) }
            cols.append(col)
        }
        // Join trends up across pauses (but not across times the app wasn't running).
        let allowed = cols.map(\.hasData)
        for kp in [\Column.p10, \.p25, \.p50, \.p75, \.p90, \.background] as [WritableKeyPath<Column, Float?>] {
            let filled = GraphUtil.fillGaps(cols.map { $0[keyPath: kp] }, allowed: allowed)
            for k in cols.indices { cols[k][keyPath: kp] = filled[k] }
        }
        // Light smoothing (±2 columns) to take the steps out of the percentiles.
        let paths: [WritableKeyPath<Column, Float?>] = [\.p10, \.p25, \.p50, \.p75, \.p90, \.background]
        for kp in paths {
            let src = cols.map { $0[keyPath: kp] }
            for k in cols.indices where src[k] != nil {
                var sum: Float = 0, cnt: Float = 0
                for m in max(0, k - 2)...min(cols.count - 1, k + 2) {
                    if let v = src[m] { sum += v; cnt += 1 }
                }
                cols[k][keyPath: kp] = sum / cnt
            }
        }
        return cols
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = plotRect
        let end = Date().timeIntervalSince1970
        let cols = columns(width: r.width, end: end)

        // Fit the y-axis to what's visible, so quiet mics aren't squashed at the bottom.
        var vals: [Double] = []
        for c in cols {
            for v in [c.p10, c.p90, c.background, c.baseline, c.threshold] { if let v { vals.append(Double(v)) } }
            if showRaw, let lv = c.rawLevel { vals.append(Double(lv)) }
        }
        let fit = GraphUtil.niceRange(vals)
        minDb = Float(fit.lo); maxDb = Float(fit.hi)
        let labelEvery: Float = maxDb - minDb > 50 ? 20 : 10

        NSColor.quaternaryLabelColor.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor]

        // dB grid
        for db in stride(from: minDb, through: maxDb, by: 10) {
            let yy = y(db, r)
            let major = db.truncatingRemainder(dividingBy: labelEvery) == 0
            NSColor.separatorColor.withAlphaComponent(major ? 0.6 : 0.25).setFill()
            NSRect(x: r.minX, y: yy, width: r.width, height: 0.5).fill()
            if major {
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

        let w = r.width / CGFloat(cols.count)
        func x(_ i: Int) -> CGFloat { r.minX + (CGFloat(i) + 0.5) * w }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).addClip()

        // Level-dropped / silent periods: merged blocks + a solid strip along the top.
        // Short breaks (pauses between phrases) are merged so a drop reads as one block.
        var kinds = cols.map { $0.silent ? 2 : $0.quiet ? 1 : 0 }
        let maxGap = max(3, Int(12 / columnWidth))
        var lastFlag: (idx: Int, kind: Int)?
        for k in kinds.indices where kinds[k] > 0 {
            if let lf = lastFlag, lf.kind == kinds[k], k - lf.idx > 1, k - lf.idx <= maxGap,
               ((lf.idx + 1)..<k).allSatisfy({ kinds[$0] == 0 && cols[$0].hasData }) {
                for m in (lf.idx + 1)..<k { kinds[m] = kinds[k] }
            }
            lastFlag = (k, kinds[k])
        }
        var i = 0
        while i < cols.count {
            let kind = kinds[i]
            guard kind > 0 else { i += 1; continue }
            var j = i
            while j + 1 < cols.count, kinds[j + 1] == kind { j += 1 }
            let color: NSColor = kind == 2 ? .systemRed : .systemOrange
            let rect = NSRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: CGFloat(j - i + 1) * w, height: r.height)
            color.withAlphaComponent(0.10).setFill(); rect.fill()
            color.withAlphaComponent(0.85).setFill()
            NSRect(x: rect.minX, y: r.maxY - 4, width: rect.width, height: 4).fill()
            i = j + 1
        }

        // Background noise: soft area from the bottom.
        fillArea(cols, r: r, x: x, lower: { $0.background == nil ? nil : self.minDb }, upper: { $0.background },
                 color: NSColor.tertiaryLabelColor.withAlphaComponent(0.12))
        stroke(cols, r: r, x: x, value: { $0.background }, color: NSColor.tertiaryLabelColor.withAlphaComponent(0.6), width: 1, dash: nil)

        // Optional raw detail.
        if showRaw {
            NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill()
            for (k, c) in cols.enumerated() {
                guard let lv = c.rawLevel else { continue }
                NSRect(x: r.minX + CGFloat(k) * w, y: r.minY, width: max(1, w - 0.5), height: y(lv, r) - r.minY).fill()
            }
        }

        // Speech bands + trend.
        let accent = NSColor.controlAccentColor
        fillArea(cols, r: r, x: x, lower: { $0.p10 }, upper: { $0.p90 }, color: accent.withAlphaComponent(0.13))
        fillArea(cols, r: r, x: x, lower: { $0.p25 }, upper: { $0.p75 }, color: accent.withAlphaComponent(0.30))
        stroke(cols, r: r, x: x, value: { $0.threshold }, color: .systemOrange, width: 1, dash: [2, 3])
        stroke(cols, r: r, x: x, value: { $0.baseline }, color: NSColor.labelColor.withAlphaComponent(0.6), width: 1, dash: [5, 4])
        stroke(cols, r: r, x: x, value: { $0.p50 }, color: accent, width: 2.2, dash: nil)

        // Hover
        if let hx = hoverX, hx >= r.minX, hx <= r.maxX, !cols.isEmpty {
            NSColor.labelColor.withAlphaComponent(0.5).setFill()
            NSRect(x: hx, y: r.minY, width: 1, height: r.height).fill()
            let k = min(cols.count - 1, max(0, Int((hx - r.minX) / w)))
            let c = cols[k]
            if let m = c.p50 {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: x(k) - 3.5, y: y(m, r) - 3.5, width: 7, height: 7)).fill()
            }
            onHover?(hoverText(c))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func hoverText(_ c: Column) -> String {
        let tf = DateFormatter()
        tf.dateFormat = range <= 900 ? "HH:mm:ss" : "HH:mm"
        func d(_ v: Float?) -> String { v.map { "\(Int($0.rounded()))" } ?? "—" }
        var parts = [tf.string(from: Date(timeIntervalSince1970: c.mid))]
        guard c.hasData else { return (parts + ["no data"]).joined(separator: " · ") }
        if c.p50 != nil {
            parts.append("trend \(d(c.p50)) dB")
            parts.append("typical \(d(c.p25)) to \(d(c.p75))")
        } else {
            parts.append("not talking")
        }
        if c.baseline != nil { parts.append("normal \(d(c.baseline))") }
        if c.background != nil { parts.append("background \(d(c.background))") }
        if c.silent { parts.append("SILENT") } else if c.quiet { parts.append("LEVEL DROPPED") }
        return parts.joined(separator: " · ")
    }

    /// Fills between two series, one polygon per contiguous run.
    private func fillArea(_ cols: [Column], r: NSRect, x: (Int) -> CGFloat,
                          lower: (Column) -> Float?, upper: (Column) -> Float?, color: NSColor) {
        color.setFill()
        var run: [(Int, Float, Float)] = []
        func flush() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x(run[0].0), y: y(run[0].2, r)))
            for (k, _, hi) in run.dropFirst() { p.line(to: NSPoint(x: x(k), y: y(hi, r))) }
            for (k, lo, _) in run.reversed() { p.line(to: NSPoint(x: x(k), y: y(lo, r))) }
            p.close(); p.fill()
        }
        for (k, c) in cols.enumerated() {
            if let lo = lower(c), let hi = upper(c) { run.append((k, lo, hi)) } else { flush() }
        }
        flush()
    }

    private func stroke(_ cols: [Column], r: NSRect, x: (Int) -> CGFloat,
                        value: (Column) -> Float?, color: NSColor, width: CGFloat, dash: [CGFloat]?) {
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineJoinStyle = .round
        if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
        var drawing = false
        for (k, c) in cols.enumerated() {
            guard let v = value(c) else { drawing = false; continue }
            let pt = NSPoint(x: x(k), y: y(v, r))
            drawing ? p.line(to: pt) : p.move(to: pt)
            drawing = true
        }
        color.setStroke()
        p.stroke()
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

/// Small key explaining the timeline's marks.
final class LegendView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 16) }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let accent = NSColor.controlAccentColor
        var x: CGFloat = 44   // line up with the plot's left edge
        let midY = bounds.midY
        func item(_ label: String, _ swatch: (NSRect) -> Void) {
            let sw = NSRect(x: x, y: midY - 5, width: 18, height: 10)
            swatch(sw)
            let s = label as NSString
            s.draw(at: NSPoint(x: x + 23, y: midY - s.size(withAttributes: attrs).height / 2), withAttributes: attrs)
            x += 23 + s.size(withAttributes: attrs).width + 12
        }
        func line(_ r: NSRect, _ c: NSColor, _ w: CGFloat, _ dash: [CGFloat]?) {
            let p = NSBezierPath(); p.lineWidth = w
            if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
            p.move(to: NSPoint(x: r.minX, y: r.midY)); p.line(to: NSPoint(x: r.maxX, y: r.midY))
            c.setStroke(); p.stroke()
        }
        item("Trend") { line($0, accent, 2.2, nil) }
        item("Typical") { accent.withAlphaComponent(0.30).setFill(); $0.fill() }
        item("Full range") { accent.withAlphaComponent(0.13).setFill(); $0.fill() }
        item("Normal") { line($0, NSColor.labelColor.withAlphaComponent(0.6), 1, [5, 4]) }
        item("Alert line") { line($0, .systemOrange, 1, [2, 3]) }
        item("Background") { NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setFill(); $0.fill() }
        item("Dropped") { NSColor.systemOrange.withAlphaComponent(0.85).setFill(); NSRect(x: $0.minX, y: $0.maxY - 4, width: $0.width, height: 4).fill() }
        item("Silent") { NSColor.systemRed.withAlphaComponent(0.85).setFill(); NSRect(x: $0.minX, y: $0.maxY - 4, width: $0.width, height: 4).fill() }
    }
}

/// Resizable window around the timeline, with range picker and summary.
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: HistoryStore
    private let timeline = TimelineView()
    private let rangeControl: NSSegmentedControl
    private let onTopCheck = NSButton(checkboxWithTitle: "Keep on top", target: nil, action: nil)
    private let rawCheck = NSButton(checkboxWithTitle: "Show raw level", target: nil, action: nil)
    private let legend = LegendView()
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

        rawCheck.target = self
        rawCheck.action = #selector(toggleRaw)
        rawCheck.state = defaults.bool(forKey: "historyShowRaw") ? .on : .off
        timeline.showRaw = rawCheck.state == .on

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

        let top = NSStackView(views: [rangeControl, onTopCheck, rawCheck, NSView(), folderButton])
        top.orientation = .horizontal
        top.spacing = 12
        let bottom = NSStackView(views: [summary, NSView(), hoverLabel])
        bottom.orientation = .horizontal
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hoverLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [top, timeline, legend, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [top, timeline, legend, bottom].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
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
            legend.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            legend.heightAnchor.constraint(equalToConstant: 16),
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

    @objc private func toggleRaw() {
        timeline.showRaw = rawCheck.state == .on
        UserDefaults.standard.set(timeline.showRaw, forKey: "historyShowRaw")
        refresh()
    }

    @objc private func toggleOnTop() {
        let on = onTopCheck.state == .on
        window?.level = on ? .floating : .normal
        UserDefaults.standard.set(on, forKey: "historyOnTop")
    }

    @objc private func openFolder() { openDataFolder?() }
}
