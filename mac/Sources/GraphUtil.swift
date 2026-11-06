import Foundation

enum GraphUtil {
    /// Linearly interpolates interior gaps (nil runs) so a trend reads as one
    /// continuous line through pauses. Gaps are only bridged where every
    /// index in between is `allowed` (e.g. the app was running); leading and
    /// trailing gaps are left alone.
    static func fillGaps<T: BinaryFloatingPoint>(_ v: [T?], allowed: [Bool]? = nil) -> [T?] {
        var out = v
        var lastIdx: Int?
        for i in v.indices {
            if let allowed, !allowed[i] { lastIdx = nil; continue }
            guard let cur = v[i] else { continue }
            if let li = lastIdx, i - li > 1, let prev = v[li] {
                for k in (li + 1)..<i {
                    let f = T(k - li) / T(i - li)
                    out[k] = prev + (cur - prev) * f
                }
            }
            lastIdx = i
        }
        return out
    }

    /// A y-axis range that fits the data with a little headroom, snapped to
    /// 10 dB, at least `minSpan` tall, within -110…0 dB.
    static func niceRange(_ values: [Double], minSpan: Double = 30) -> (lo: Double, hi: Double) {
        let vals = values.filter { $0.isFinite && $0 > -110 }
        guard let mn = vals.min(), let mx = vals.max() else { return (-70, 0) }
        var lo = ((mn - 4) / 10).rounded(.down) * 10
        var hi = ((mx + 4) / 10).rounded(.up) * 10
        if hi - lo < minSpan {
            let extra = minSpan - (hi - lo)
            hi += (extra / 2 / 10).rounded(.up) * 10
            lo = hi - max(minSpan, hi - lo)
        }
        hi = min(hi, 0); lo = max(lo, -110)
        if hi - lo < minSpan { lo = max(-110, hi - minSpan) }
        return (lo, hi)
    }
}
