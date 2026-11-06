import AppKit

/// Last ~60 s of mic activity, shown at the top of the menu.
///  faint bars  = raw level
///  blue bands  = spread of your speech level (middle 50% darker, 10–90% lighter)
///  blue line   = trend (median speech level), joined up across pauses
///  dashed line = your normal level (baseline)
///  orange line = the "level dropped" threshold
/// The y-axis zooms to fit your levels, so a quiet mic still fills the graph.
final class GraphView: NSView {
    weak var detector: LevelDetector?
    var headline = ""
    var subline = ""
    var onClick: (() -> Void)?

    // Displayed y-range; eases toward the data so it doesn't jump around.
    private var lo = -70.0, hi = 0.0
    private var rangeInitialised = false

    override var isFlipped: Bool { false }

    override func mouseUp(with event: NSEvent) { onClick?() }

    private func y(_ db: Double, in r: NSRect) -> CGFloat {
        let t = (min(max(db, lo), hi) - lo) / (hi - lo)
        return r.minY + CGFloat(t) * r.height
    }

    private struct Col {
        var x: CGFloat
        var p10: Double?, p25: Double?, p50: Double?, p75: Double?, p90: Double?
        var noise: Double?
        var live = false   // there is detector data for this column
    }

    override func draw(_ dirtyRect: NSRect) {
        let pad: CGFloat = 14
        let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let axisAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        (headline as NSString).draw(at: NSPoint(x: pad, y: bounds.maxY - 22), withAttributes: headAttrs)
        (subline as NSString).draw(at: NSPoint(x: pad, y: bounds.maxY - 38), withAttributes: subAttrs)

        let axisW: CGFloat = 26
        let r = NSRect(x: pad + axisW, y: 8, width: bounds.width - pad * 2 - axisW, height: bounds.height - 56)
        let bg = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        bg.fill()

        guard let d = detector else { return }
        let hist = d.history
        let n = d.historyLength
        let offset = n - hist.count

        // Columns: spread of speech levels in a ~4 s window around each.
        let colCount = max(1, Int(r.width / 2))
        let half = 24
        var cols: [Col] = []
        for c in 0..<colCount {
            let frameIdx = Int((Double(c) + 0.5) / Double(colCount) * Double(n)) - offset
            var col = Col(x: r.minX + (CGFloat(c) + 0.5) * r.width / CGFloat(colCount))
            if frameIdx >= 0 && frameIdx < hist.count {
                col.live = true
                col.noise = hist[frameIdx].noise
                var v: [Double] = []
                for k in max(0, frameIdx - half)...min(hist.count - 1, frameIdx + half) where hist[k].speech != nil {
                    v.append(hist[k].db)
                }
                if v.count >= 3 {
                    v.sort()
                    func q(_ p: Double) -> Double {
                        let idx = p * Double(v.count - 1)
                        let a = Int(idx), b = min(v.count - 1, a + 1)
                        return v[a] + (v[b] - v[a]) * (idx - Double(a))
                    }
                    col.p10 = q(0.1); col.p25 = q(0.25); col.p50 = q(0.5); col.p75 = q(0.75); col.p90 = q(0.9)
                }
            }
            cols.append(col)
        }
        // Join the trend and bands up across pauses.
        let allowed = cols.map(\.live)
        let keys: [WritableKeyPath<Col, Double?>] = [\.p10, \.p25, \.p50, \.p75, \.p90]
        for kp in keys {
            let filled = GraphUtil.fillGaps(cols.map { $0[keyPath: kp] }, allowed: allowed)
            for i in cols.indices { cols[i][keyPath: kp] = filled[i] }
        }

        // Fit the y-axis to what's on screen (speech, background, normal, alert line).
        var vals: [Double] = cols.compactMap(\.p10) + cols.compactMap(\.p90) + cols.compactMap(\.noise)
        if let b = d.baseline { vals += [b, b - d.dropDb] }
        let target = GraphUtil.niceRange(vals)
        if !rangeInitialised || vals.isEmpty {
            (lo, hi) = target; rangeInitialised = !vals.isEmpty
        } else {
            lo += (target.lo - lo) * 0.15
            hi += (target.hi - hi) * 0.15
        }

        // dB grid + labels
        var g = (lo / 10).rounded(.up) * 10
        while g <= hi {
            let yy = y(g, in: r)
            NSColor.separatorColor.withAlphaComponent(0.35).setFill()
            NSRect(x: r.minX, y: yy, width: r.width, height: 0.5).fill()
            let s = "\(Int(g))" as NSString
            let sz = s.size(withAttributes: axisAttrs)
            if yy - sz.height / 2 > r.minY - 2 && yy + sz.height / 2 < r.maxY + 2 {
                s.draw(at: NSPoint(x: r.minX - sz.width - 4, y: yy - sz.height / 2), withAttributes: axisAttrs)
            }
            g += 10
        }

        NSGraphicsContext.saveGraphicsState()
        bg.addClip()

        // Faint raw level so the graph still feels live.
        let step = r.width / CGFloat(n)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.12).setFill()
        for (i, s) in hist.enumerated() {
            let x = r.minX + CGFloat(i + offset) * step
            NSRect(x: x, y: r.minY, width: max(step, 1), height: y(s.db, in: r) - r.minY).fill()
        }

        func area(_ lower: (Col) -> Double?, _ upper: (Col) -> Double?, _ color: NSColor) {
            color.setFill()
            var run: [(CGFloat, Double, Double)] = []
            func flush() {
                defer { run = [] }
                guard run.count >= 2 else { return }
                let p = NSBezierPath()
                p.move(to: NSPoint(x: run[0].0, y: y(run[0].2, in: r)))
                for (x, _, h) in run.dropFirst() { p.line(to: NSPoint(x: x, y: y(h, in: r))) }
                for (x, l, _) in run.reversed() { p.line(to: NSPoint(x: x, y: y(l, in: r))) }
                p.close(); p.fill()
            }
            for c in cols { if let l = lower(c), let h = upper(c) { run.append((c.x, l, h)) } else { flush() } }
            flush()
        }
        let floorDb = lo
        area({ $0.noise == nil ? nil : floorDb }, { $0.noise }, NSColor.tertiaryLabelColor.withAlphaComponent(0.14))
        let accent = NSColor.controlAccentColor
        area({ $0.p10 }, { $0.p90 }, accent.withAlphaComponent(0.14))
        area({ $0.p25 }, { $0.p75 }, accent.withAlphaComponent(0.32))

        if let b = d.baseline {
            for (value, color, dash) in [(b, NSColor.labelColor.withAlphaComponent(0.6), [CGFloat(4), 3]),
                                         (b - d.dropDb, NSColor.systemOrange, [CGFloat(2), 3])] {
                let p = NSBezierPath()
                p.move(to: NSPoint(x: r.minX, y: y(value, in: r)))
                p.line(to: NSPoint(x: r.maxX, y: y(value, in: r)))
                p.setLineDash(dash, count: 2, phase: 0)
                p.lineWidth = 1
                color.setStroke(); p.stroke()
            }
        }

        let trend = NSBezierPath()
        trend.lineWidth = 2.2
        trend.lineJoinStyle = .round
        var drawing = false
        for c in cols {
            guard let m = c.p50 else { drawing = false; continue }
            let p = NSPoint(x: c.x, y: y(m, in: r))
            drawing ? trend.line(to: p) : trend.move(to: p)
            drawing = true
        }
        accent.setStroke()
        trend.stroke()
        NSGraphicsContext.restoreGraphicsState()

        let hint = "Click for full history" as NSString
        let hintAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
        hint.draw(at: NSPoint(x: r.maxX - hint.size(withAttributes: hintAttrs).width - 6, y: r.maxY - 15), withAttributes: hintAttrs)
    }
}
