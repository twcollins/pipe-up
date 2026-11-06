import AppKit

/// What we know about the audio setup at the moment a drop is analysed.
struct DiagContext {
    var deviceName = "—"
    var transport = "Unknown"
    var sampleRate: Double?
    var channels = 0
    var volume: Float?
    var volumeAtBaseline: Float?
    var muted = false
    var micMode = "—"
    var appsUsingMic: [String]?
    var lastDeviceSwitch: Date?
    var lastSampleRateChange: (date: Date, from: Double, to: Double)?
    var lastVolumeDrop: (date: Date, from: Float, to: Float, apps: [String])?
}

struct Diagnosis {
    struct Finding { var short: String; var text: String }
    var time = Date()
    var drop: Double?
    var headline: String
    var findings: [Finding]
    var likely: String? { findings.first?.short }

    var report: String {
        var lines = [headline]
        for (i, f) in findings.enumerated() { lines.append("\(i == 0 ? "Most likely" : "Also"): \(f.text)") }
        return lines.joined(separator: "\n")
    }
}

/// Works out the likely cause of a level drop from the evidence available.
///
/// The key idea: a drop in *gain* (input volume, auto-gain, a gain knob, a
/// different mic) lowers your voice and the background noise together. An
/// *acoustic* change (you moved away, turned your head, spoke more softly)
/// lowers your voice but leaves the background where it was. A mic that's
/// covered or pointing away also loses treble.
enum Diagnoser {
    static func diagnose(_ d: LevelDetector, _ c: DiagContext, now: Date = Date()) -> Diagnosis {
        var f: [Diagnosis.Finding] = []
        let drop = d.dropAmount
        func ago(_ t: Date) -> String { HistoryWindowController.duration(Int(now.timeIntervalSince(t))) + " ago" }
        func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }
        func db(_ v: Double) -> String { String(format: "%.0f dB", v) }

        if c.muted {
            f.append(.init(short: "mic muted", text: "The input is muted in macOS."))
        }
        if let sw = c.lastDeviceSwitch, now.timeIntervalSince(sw) < 120 {
            f.append(.init(short: "mic switched",
                           text: "The input switched to \(c.deviceName) \(ago(sw)). Different mics have different levels. This usually happens when headphones or a headset connect."))
        }
        if let sr = c.lastSampleRateChange, now.timeIntervalSince(sr.date) < 120 {
            f.append(.init(short: "mic format changed",
                           text: "The mic's sample rate changed from \(Int(sr.from)) to \(Int(sr.to)) Hz \(ago(sr.date)). On Bluetooth headsets this means they switched into call mode, which changes the level and quality."))
        }
        if let vb = c.volumeAtBaseline, let v = c.volume, v < vb - 0.04 {
            var t = "macOS input volume is \(pct(v)), down from \(pct(vb)) when your normal level was learnt."
            if let ch = c.lastVolumeDrop, !ch.apps.isEmpty {
                t += " Apps using the mic when it changed: \(ch.apps.joined(separator: ", ")). Their automatic gain control is the usual culprit. Turn it off in the app's audio settings, or use Lock input volume."
            }
            f.append(.init(short: "input volume lowered", text: t))
        }

        var acoustic = false
        if let drop, drop > 2, d.sincePause > 4 {
            f.append(.init(short: "unclear (no pause yet)",
                           text: "You haven't paused since the drop, so the background can't be measured yet. Pause briefly and check again."))
        } else if let drop, drop > 2, let nb = d.baselineNoiseFloor {
            let nfDrop = nb - d.noiseFloor
            if nfDrop >= max(3, 0.5 * drop) {
                f.append(.init(short: "gain dropped",
                               text: "Background noise fell \(db(nfDrop)) along with your voice (\(db(drop))). The whole signal got quieter, so something reduced the gain: an app's auto-gain, a gain knob on a headset or interface, or a different mic."))
            } else if nfDrop <= -4 {
                f.append(.init(short: "louder background",
                               text: "Background noise is \(db(-nfDrop)) louder than normal, so your voice stands out less."))
            } else if abs(nfDrop) < 3 {
                acoustic = true
            } else {
                f.append(.init(short: "gain + distance",
                               text: "Background noise fell \(db(nfDrop)) but your voice fell more (\(db(drop))). Probably a mix: some gain reduction plus being further from the mic or speaking more softly."))
            }
        }
        if let bb = d.baselineBrightness, let b = d.brightness, bb - b >= 3, (drop ?? 0) > 2 {
            f.append(.init(short: "mic muffled / turned away",
                           text: "Your voice has lost \(db(bb - b)) of treble compared with normal. The mic is probably pointing away from your mouth or is covered (hand, clothing, mask, or a moved headset boom)."))
        }
        if acoustic, let drop {
            f.append(.init(short: "further from mic / softer",
                           text: "Background noise is unchanged but your voice is \(db(drop)) quieter. That points to an acoustic change: you're further from the mic, facing away, or speaking more softly."))
        }

        let headline: String
        if d.baseline == nil {
            headline = "Still learning your normal level. Talk for a few more seconds."
        } else if let drop, drop > 2 {
            headline = "Your voice is \(db(drop)) below your normal level."
        } else {
            headline = "Your level is normal right now (within 2 dB)."
        }
        if f.isEmpty, let drop, drop > 2 {
            f.append(.init(short: "unclear",
                           text: "No clear cause yet. Keep talking for a few seconds and check again."))
        }
        if c.transport == "Bluetooth" {
            f.append(.init(short: "bluetooth", text: "This is a Bluetooth mic. Its level and quality can change with the connection and with call mode."))
        }
        if c.micMode == "Voice Isolation" {
            f.append(.init(short: "voice isolation",
                           text: "macOS Mic Mode is Voice Isolation. Meeting apps that use it can make you sound quieter or processed. Pipe Up measures the raw mic, so it won't see that effect."))
        }
        return Diagnosis(time: now, drop: drop, headline: headline, findings: f)
    }
}

/// Expert window: live mic diagnostics, latest diagnosis, and event log.
final class DiagnosticsWindowController: NSWindowController, NSWindowDelegate {
    var liveText: (() -> String)?
    var runCheck: (() -> Diagnosis)?
    var logLines: (() -> [String])?

    private let live = NSTextField(labelWithString: "")
    private let diagnosisLabel = NSTextField(wrappingLabelWithString: "")
    private let logView = NSTextView()
    private var timer: Timer?
    private var lastLogCount = -1

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Pipe Up: Diagnostics"
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        live.font = mono
        live.maximumNumberOfLines = 0
        live.lineBreakMode = .byWordWrapping
        diagnosisLabel.font = .systemFont(ofSize: 13)
        diagnosisLabel.isSelectable = true

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        let scroll = NSScrollView()
        scroll.documentView = logView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true

        func heading(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .systemFont(ofSize: 12, weight: .semibold)
            t.textColor = .secondaryLabelColor
            return t
        }
        let check = NSButton(title: "Check now", target: self, action: #selector(checkNow))
        check.bezelStyle = .rounded
        check.keyEquivalent = "\r"
        let copy = NSButton(title: "Copy report", target: self, action: #selector(copyReport))
        copy.bezelStyle = .rounded
        let buttons = NSStackView(views: [check, copy])

        let stack = NSStackView(views: [heading("NOW"), live, heading("WHY AM I QUIET?"), diagnosisLabel, buttons,
                                        heading("RECENT EVENTS"), scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: live)
        stack.setCustomSpacing(16, after: buttons)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            live.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            diagnosisLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = content
        window.setFrameAutosaveName("DiagnosticsWindow")
        if !window.setFrameUsingName("DiagnosticsWindow") { window.center() }
        diagnosisLabel.stringValue = "Click Check now to analyse your current level. Any drop is analysed automatically when it happens."
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

    /// Called when a drop is diagnosed automatically.
    func show(diagnosis: Diagnosis) {
        diagnosisLabel.stringValue = Self.format(diagnosis)
    }

    func refresh() {
        guard window?.isVisible == true else { return }
        live.stringValue = liveText?() ?? ""
        let lines = logLines?() ?? []
        if lines.count != lastLogCount {
            lastLogCount = lines.count
            logView.string = lines.reversed().joined(separator: "\n")
        }
    }

    private static func format(_ d: Diagnosis) -> String {
        let tf = DateFormatter()
        tf.dateFormat = "HH:mm:ss"
        return "[\(tf.string(from: d.time))] " + d.report
    }

    @objc private func checkNow() {
        guard let d = runCheck?() else { return }
        diagnosisLabel.stringValue = Self.format(d)
    }

    @objc private func copyReport() {
        let report = """
        Pipe Up diagnostics report: \(Date())

        \(liveText?() ?? "")

        \(diagnosisLabel.stringValue)

        Recent events:
        \((logLines?() ?? []).suffix(40).joined(separator: "\n"))
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
