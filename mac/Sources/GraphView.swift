import AppKit

/// Last ~60 s of mic activity, shown at the top of the menu.
///  grey bars   = raw level
///  blue line   = your speaking level (short-term)
///  dashed line = your normal level (baseline)
///  orange line = the "you've gone quiet" threshold
final class GraphView: NSView {
    weak var detector: LevelDetector?
    var headline = ""
    var subline = ""

    private let minDb = -70.0, maxDb = 0.0

    override var isFlipped: Bool { false }

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

        // Raw level bars.
        NSColor.tertiaryLabelColor.setFill()
        for (i, s) in hist.enumerated() {
            let x = r.minX + CGFloat(i + offset) * step
            let top = y(s.db, in: r)
            NSRect(x: x, y: r.minY, width: max(step, 1), height: top - r.minY).fill()
        }

        // Speaking level line.
        let line = NSBezierPath()
        line.lineWidth = 1.8
        var drawing = false
        for (i, s) in hist.enumerated() {
            let x = r.minX + CGFloat(i + offset) * step
            if let sp = s.speech {
                let p = NSPoint(x: x, y: y(sp, in: r))
                drawing ? line.line(to: p) : line.move(to: p)
                drawing = true
            } else {
                drawing = false
            }
        }
        NSColor.controlAccentColor.setStroke()
        line.stroke()

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
    }
}
