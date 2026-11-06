import Foundation

/// One second of mic activity.
struct HistoryRecord {
    enum State: UInt8 { case calibrating = 0, ok, quiet, silent
        var name: String { ["calibrating", "ok", "quiet", "silent"][Int(rawValue)] }
        init?(name: String) {
            guard let i = ["calibrating", "ok", "quiet", "silent"].firstIndex(of: name) else { return nil }
            self.init(rawValue: UInt8(i))
        }
    }
    var time: TimeInterval        // seconds since 1970
    var level: Float              // mean level over the second (dBFS)
    var peak: Float               // loudest frame in the second (dBFS)
    var speech: Float?            // mean level of speech frames, if you spoke
    var baseline: Float?          // your "normal" level at the time
    var threshold: Float?         // alert line at the time
    var state: State
    var volume: Float?            // macOS input volume 0…1
    var noiseFloor: Float? = nil  // background noise level (dBFS)
    var brightness: Float? = nil  // treble vs overall level while speaking (dB)
}

/// Keeps the last 24 h in memory and appends everything to daily CSV files:
///   ~/Library/Application Support/PipeUp/history/YYYY-MM-DD.csv  (1 row/second)
///   ~/Library/Application Support/PipeUp/events.csv               (alerts, device changes…)
final class HistoryStore {
    static let header = "timestamp,epoch,level_db,peak_db,speech_db,normal_db,alert_line_db,state,input_volume,device,noise_floor_db,brightness_db\n"
    static let eventsHeader = "timestamp,epoch,event,detail\n"
    let keepInMemory: TimeInterval = 24 * 3600
    let keepOnDiskDays = 90

    let folder: URL
    private var historyFolder: URL { folder.appendingPathComponent("history", isDirectory: true) }
    private var eventsURL: URL { folder.appendingPathComponent("events.csv") }

    private(set) var records: [HistoryRecord] = []
    private var pending: [(day: String, line: String)] = []
    private var pendingEvents: [String] = []
    private let io = DispatchQueue(label: "pipe-up.history")
    private var lastFlush = Date()

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init(folder: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.folder = folder ?? base.appendingPathComponent("PipeUp", isDirectory: true)
        if folder == nil {
            // The app used to be called Mic Helper — carry its history over.
            let old = base.appendingPathComponent("MicHelper", isDirectory: true)
            let fm = FileManager.default
            if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: self.folder.path) {
                try? fm.moveItem(at: old, to: self.folder)
            }
        }
        try? FileManager.default.createDirectory(at: historyFolder, withIntermediateDirectories: true)
    }

    // MARK: Loading

    /// Loads today's and yesterday's files so the graph survives restarts.
    func load(completion: @escaping () -> Void) {
        io.async { [self] in
            let cutoff = Date().timeIntervalSince1970 - keepInMemory
            var loaded: [HistoryRecord] = []
            for daysAgo in [1, 0] {
                let day = dayFormatter.string(from: Date().addingTimeInterval(-Double(daysAgo) * 86400))
                let url = historyFolder.appendingPathComponent("\(day).csv")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n").dropFirst() {
                    if let r = Self.parse(line), r.time >= cutoff { loaded.append(r) }
                }
            }
            pruneOldFiles()
            DispatchQueue.main.async {
                // Anything recorded while loading goes after the loaded data.
                self.records = loaded + self.records.filter { $0.time > (loaded.last?.time ?? 0) }
                completion()
            }
        }
    }

    private static func parse(_ line: Substring) -> HistoryRecord? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false)
        guard f.count >= 9, let t = Double(f[1]), let lv = Float(f[2]), let pk = Float(f[3]),
              let st = HistoryRecord.State(name: String(f[7])) else { return nil }
        return HistoryRecord(time: t, level: lv, peak: pk, speech: Float(f[4]), baseline: Float(f[5]),
                             threshold: Float(f[6]), state: st, volume: Float(f[8]))
    }

    private func pruneOldFiles() {
        let cutoff = Date().addingTimeInterval(-Double(keepOnDiskDays) * 86400)
        let files = (try? FileManager.default.contentsOfDirectory(at: historyFolder, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "csv" {
            if let d = dayFormatter.date(from: url.deletingPathExtension().lastPathComponent), d < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: Writing

    func append(_ r: HistoryRecord, device: String) {
        records.append(r)
        let cutoff = r.time - keepInMemory
        if let first = records.first, first.time < cutoff {
            records.removeFirst(records.firstIndex { $0.time >= cutoff } ?? 0)
        }

        let date = Date(timeIntervalSince1970: r.time)
        func n(_ v: Float?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        let line = [isoFormatter.string(from: date), String(format: "%.0f", r.time), n(r.level), n(r.peak),
                    n(r.speech), n(r.baseline), n(r.threshold), r.state.name,
                    r.volume.map { String(format: "%.2f", $0) } ?? "", csvEscape(device),
                    n(r.noiseFloor), n(r.brightness)].joined(separator: ",")
        pending.append((dayFormatter.string(from: date), line))
        if Date().timeIntervalSince(lastFlush) > 10 { flush() }
    }

    func event(_ name: String, _ detail: String = "") {
        let now = Date()
        pendingEvents.append([isoFormatter.string(from: now), String(format: "%.0f", now.timeIntervalSince1970),
                              name, csvEscape(detail)].joined(separator: ","))
        flush()
    }

    func flush(sync: Bool = false) {
        lastFlush = Date()
        let rows = pending, events = pendingEvents
        pending = []; pendingEvents = []
        guard !rows.isEmpty || !events.isEmpty else {
            if sync { io.sync {} }   // still wait for earlier async writes (e.g. at quit)
            return
        }
        let work = { [self] in
            for (day, lines) in Dictionary(grouping: rows, by: { $0.day }) {
                let url = historyFolder.appendingPathComponent("\(day).csv")
                appendLines(lines.map(\.line), to: url, header: Self.header)
            }
            if !events.isEmpty { appendLines(events, to: eventsURL, header: Self.eventsHeader) }
        }
        sync ? io.sync(execute: work) : io.async(execute: work)
    }

    private func appendLines(_ lines: [String], to url: URL, header: String) {
        let body = lines.joined(separator: "\n") + "\n"
        if !FileManager.default.fileExists(atPath: url.path) {
            try? (header + body).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(body.utf8))
    }

    private func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    // MARK: Queries

    /// Index of the first record at or after `time` (binary search).
    func firstIndex(atOrAfter time: TimeInterval) -> Int {
        var lo = 0, hi = records.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if records[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
