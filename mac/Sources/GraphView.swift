import AppKit

/// Last ~60 s of mic activity, shown at the top of the menu.
///  faint bars  = raw level
///  blue bands  = spread of your speech level (middle 50% darker, 10–90% lighter)
///  blue line   = trend (median speech level)
///  dashed line = your normal level (baseline)
///  orange line = the "level dropped" threshold
final class GraphView: NSView {
    weak var detector: LevelDetector?
    var headline = ""
    var subline = ""
    var onClick: (() -> Void)?

    private let minDb = -70.0, maxDb = 0.0

    override var isFlipped: Bool { false }

    override func mouseUp(with event: NSEvent) { onClick?() }

    private func y(_ db: Double, in r: NSRect) -> CGFloat {
        let t = (min(max(db, minDb), maxDb) - minDb) / (maxDb - minDb)
        return r.minY + CGFloat(t) * r.height
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (headline as NSString).draw(at: NSPoint(x: pad, y: bounds.maxY - 22), withAttributes: headAttrs)
        (subline as NSString).draw(at: NSPoint(x: pad, y: bounds.maxY - 38), withAttributes: subAttrs)

        let r = NSRect(x: pad, y: 8, width: bounds.width - pad * 2, height: bounds.height - 56)
        let bg = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        bg.fill()

        guard let d = detector else { return }
        NSGraphicsContext.saveGraphicsState()
        bg.addClip()

        let hist = d.history
        let n = d.historyLength
        let step = r.width / CGFloat(n)
        let offset = n - hist.count

        // Faint raw level so the graph still feels live.
        NSColor.tertiaryLabelColor.withAlphaComponent(0.10).setFill()
        for (i, s) in hist.enumerated() {
            let x = r.minX + CGFloat(i + offset) * step
            NSRect(x: x, y: r.minY, width: max(step, 1), height: y(s.db, in: r) - r.minY).fill()
        }

        // Smoothed view: for each 2 px column, the spread of speech levels in a
        // ~2.5 s window around it (band) and its median (trend).
        struct Col { var x: CGFloat; var lo: Double?; var q1: Double?; var med: Double?; var q3: Double?; var hi: Double?; var noise: Double? }
        let colCount = max(1, Int(r.width / 2))
        let half = 15   // frames either side (~1.3 s)
        var cols: [Col] = []
        for c in 0..<colCount {
            let frameIdx = Int((Double(c) + 0.5) / Double(colCount) * Double(n)) - offset
            var col = Col(x: r.minX + (CGFloat(c) + 0.5) * r.width / CGFloat(colCount))
            if frameIdx >= 0 && frameIdx < hist.count {
                col.noise = hist[frameIdx].noise
                var v: [Double] = []
                for k in max(0, frameIdx - half)...min(hist.count - 1, frameIdx + half) where hist[k].speech != nil {
                    v.append(hist[k].db)
                }
                if v.count >= 4 {
                    v.sort()
                    func q(_ p: Double) -> Double { v[min(v.count - 1, Int(p * Double(v.count - 1) + 0.5))] }
                    col.lo = q(0.1); col.q1 = q(0.25); col.med = q(0.5); col.q3 = q(0.75); col.hi = q(0.9)
                }
            }
            cols.append(col)
        }
        func area(_ lower: (Col) -> Double?, _ upper: (Col) -> Double?, _ color: NSColor) {
            color.setFill()
            var run: [(CGFloat, Double, Double)] = []
            func flush() {
                defer { run = [] }
                guard run.count >= 2 else { return }
                let p = NSBezierPath()
                p.move(to: NSPoint(x: run[0].0, y: y(run[0].2, in: r)))
                for (x, _, hi) in run.dropFirst() { p.line(to: NSPoint(x: x, y: y(hi, in: r))) }
                for (x, lo, _) in run.reversed() { p.line(to: NSPoint(x: x, y: y(lo, in: r))) }
                p.close(); p.fill()
            }
            for c in cols { if let lo = lower(c), let hi = upper(c) { run.append((c.x, lo, hi)) } else { flush() } }
            flush()
        }
        area({ $0.noise == nil ? nil : self.minDb }, { $0.noise }, NSColor.tertiaryLabelColor.withAlphaComponent(0.12))
        let accent = NSColor.controlAccentColor
        area({ $0.lo }, { $0.hi }, accent.withAlphaComponent(0.13))
        area({ $0.q1 }, { $0.q3 }, accent.withAlphaComponent(0.30))
        let trend = NSBezierPath()
        trend.lineWidth = 2
        trend.lineJoinStyle = .round
        var drawing = false
        for c in cols {
            guard let m = c.med else { drawing = false; continue }
            let p = NSPoint(x: c.x, y: y(m, in: r))
            drawing ? trend.line(to: p) : trend.move(to: p)
            drawing = true
        }
        accent.setStroke()
        trend.stroke()

        if let b = d.baseline {
            let base = NSBezierPath()
            base.move(to: NSPoint(x: r.minX, y: y(b, in: r)))
            base.line(to: NSPoint(x: r.maxX, y: y(b, in: r)))
            base.setLineDash([4, 3], count: 2, phase: 0)
            base.lineWidth = 1
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            base.stroke()

            let thr = NSBezierPath()
            thr.move(to: NSPoint(x: r.minX, y: y(b - d.dropDb, in: r)))
            thr.line(to: NSPoint(x: r.maxX, y: y(b - d.dropDb, in: r)))
            thr.setLineDash([2, 3], count: 2, phase: 0)
            thr.lineWidth = 1
            NSColor.systemOrange.setStroke()
            thr.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let hint = "Click for full history" as NSString
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
        // Drawn last, inside the graph's top-right corner so it never collides with the headline.
        hint.draw(at: NSPoint(x: bounds.maxX - pad - hint.size(withAttributes: hintAttrs).width - 6, y: bounds.height - 48 - 14), withAttributes: hintAttrs)
    }
}
