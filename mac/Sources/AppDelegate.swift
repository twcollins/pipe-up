import AppKit
import AVFoundation
import CoreAudio
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let defaults = UserDefaults.standard
    private let detector = LevelDetector()
    private let monitor = AudioMonitor()
    private let hud = HUD()
    private let history = HistoryStore()
    private lazy var historyWindow: HistoryWindowController = {
        let c = HistoryWindowController(store: history)
        c.openDataFolder = { [weak self] in self?.openDataFolder() }
        return c
    }()

    // Per-second accumulator for the history log.
    private var accSecond = 0
    private var accEnergy = 0.0, accDur = 0.0, accPeak = -200.0
    private var accSpeechSum = 0.0, accSpeechN = 0
    private var accState: HistoryRecord.State = .calibrating

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let graph = GraphView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))
    private let deviceItem = NSMenuItem(title: "Mic: —", action: nil, keyEquivalent: "")
    private let volumeLabel = NSTextField(labelWithString: "Input volume")
    private let volumeSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var volumeItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var hudItem: NSMenuItem!
    private var silentItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var privacyItem: NSMenuItem!
    private var sensitivityItems: [NSMenuItem] = []

    private var device: AudioDeviceID?
    private var deviceName = "—"
    private var lastVolume: Float?
    private var muted = false
    private var permissionDenied = false
    private var audioError: String?

    private var defaultInputToken: CoreAudioDevice.Token?
    private var volumeTokens: [CoreAudioDevice.Token] = []
    private var restartWork: DispatchWorkItem?

    private var lastState: LevelDetector.State = .calibrating
    private var displayLevel: Double = 0
    private var lastSound = Date.distantPast
    private var hudShowsAlert = false
    private var lastHudText = ""
    private var menuOpen = false

    // MARK: Settings

    private var dropDb: Double {
        get { defaults.object(forKey: "dropDb") as? Double ?? 8 }
        set { defaults.set(newValue, forKey: "dropDb"); detector.dropDb = newValue }
    }
    private func flag(_ key: String, default def: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? def }
    private var showHUD: Bool { flag("showHUD", default: true) }
    private var alertSilent: Bool { flag("alertSilent", default: true) }
    private var playSound: Bool { flag("playSound", default: false) }
    private var lockVolume: Bool { flag("lockVolume", default: false) }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        detector.dropDb = dropDb
        graph.detector = detector
        graph.onClick = { [weak self] in
            self?.menu.cancelTracking()
            self?.showHistory()
        }
        history.load { [weak self] in self?.historyWindow.refresh() }
        history.event("app_started")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeft
        buildMenu()
        statusItem.menu = menu
        renderStatusIcon()

        monitor.onLevel = { [weak self] db, dt in self?.handleLevel(db, dt) }
        monitor.onConfigurationChange = { [weak self] in self?.scheduleRestart(reason: nil) }
        defaultInputToken = CoreAudioDevice.listenDefaultInput { [weak self] in
            guard let self else { return }
            let new = CoreAudioDevice.defaultInputDevice()
            if new != self.device {
                let name = new.map(CoreAudioDevice.name(of:)) ?? "no device"
                self.history.event("mic_switched", name)
                self.scheduleRestart(reason: "Mic switched to \(name)")
            }
        }

        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refreshUI() }
        RunLoop.main.add(timer, forMode: .common)  // keep updating while the menu is open

        requestPermissionAndStart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        history.event("app_quit")
        history.flush(sync: true)
    }

    private func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startAudio()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { granted ? self.startAudio() : self.markDenied() }
            }
        default:
            markDenied()
        }
    }

    private func markDenied() {
        permissionDenied = true
        privacyItem.isHidden = false
    }

    // MARK: Audio / devices

    private func scheduleRestart(reason: String?) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startAudio()
            if let reason { self?.notice(reason) }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func startAudio() {
        guard !permissionDenied else { return }
        let newDevice = CoreAudioDevice.defaultInputDevice()
        if newDevice != device { detector.reset() }   // different mic = different normal level
        device = newDevice

        volumeTokens.forEach(CoreAudioDevice.remove)
        volumeTokens = []
        if let id = newDevice {
            deviceName = CoreAudioDevice.name(of: id)
            lastVolume = CoreAudioDevice.inputVolume(id)
            muted = CoreAudioDevice.isInputMuted(id)
            volumeTokens = CoreAudioDevice.listenVolume(id) { [weak self] in self?.volumeChanged() }
            if lockVolume, defaults.object(forKey: "lockedVolume") == nil, let v = lastVolume {
                defaults.set(v, forKey: "lockedVolume")
            }
        } else {
            deviceName = "No input device"
            lastVolume = nil
        }

        do {
            try monitor.start()
            audioError = nil
        } catch {
            audioError = error.localizedDescription
        }
        updateVolumeControls()
    }

    private func volumeChanged() {
        guard let id = device else { return }
        muted = CoreAudioDevice.isInputMuted(id)
        guard let v = CoreAudioDevice.inputVolume(id) else { return }
        defer { lastVolume = v; updateVolumeControls() }

        if lockVolume, let locked = defaults.object(forKey: "lockedVolume") as? Float, abs(v - locked) > 0.02 {
            CoreAudioDevice.setInputVolume(id, locked)
            history.event("input_volume_restored", "\(pct(v)) -> \(pct(locked))")
            notice("An app changed input volume to \(pct(v)) — restored \(pct(locked))")
            return
        }
        if let old = lastVolume, v < old - 0.05 {
            history.event("input_volume_lowered", "\(pct(old)) -> \(pct(v))")
            notice("Input volume lowered: \(pct(old)) → \(pct(v))")
        }
    }

    private func pct(_ v: Float) -> String { "\(Int((v * 100).rounded()))%" }

    // MARK: Level handling / alerts

    private func handleLevel(_ db: Double, _ dt: Double) {
        detector.process(db: db, dt: dt)
        let state = effectiveState
        recordHistory(db: db, dt: dt, state: state)

        if state != lastState {
            if state == .quiet, playSound, Date().timeIntervalSince(lastSound) > 20 {
                NSSound(named: "Tink")?.play()
                lastSound = Date()
            }
            if state == .quiet || state == .silent || lastState == .quiet || lastState == .silent {
                let detail = state == .quiet ? "drop \(Int((detector.dropAmount ?? 0).rounded())) dB" : ""
                history.event("state_\(state)", detail)
            }
            lastState = state
        }
        updateAlertHUD(state)
    }

    private enum UIState { case calibrating, ok, quiet, silent, muted }

    private func recordHistory(db: Double, dt: Double, state: LevelDetector.State) {
        let sec = Int(Date().timeIntervalSince1970)
        if sec != accSecond {
            if accDur > 0 {
                let d = detector
                let rec = HistoryRecord(
                    time: Double(accSecond),
                    level: Float(10 * log10(max(accEnergy / accDur, 1e-14))),
                    peak: Float(accPeak),
                    speech: accSpeechN > 0 ? Float(accSpeechSum / Double(accSpeechN)) : nil,
                    baseline: d.baseline.map(Float.init),
                    threshold: d.baseline.map { Float($0 - d.dropDb) },
                    state: accState,
                    volume: lastVolume)
                history.append(rec, device: deviceName)
            }
            accSecond = sec
            accEnergy = 0; accDur = 0; accPeak = -200; accSpeechSum = 0; accSpeechN = 0
            accState = .calibrating
        }
        accEnergy += pow(10, db / 10) * dt
        accDur += dt
        accPeak = max(accPeak, db)
        if detector.history.last?.speech != nil { accSpeechSum += db; accSpeechN += 1 }
        // Keep the most severe state seen during the second.
        let s: HistoryRecord.State = state == .silent ? .silent : state == .quiet ? .quiet : state == .ok ? .ok : .calibrating
        if s.rawValue > accState.rawValue { accState = s }
    }

    private func showHistory() { historyWindow.show() }

    private func openDataFolder() {
        history.flush()
        NSWorkspace.shared.open(history.folder)
    }

    private var effectiveState: LevelDetector.State { muted ? .silent : detector.state }

    private func updateAlertHUD(_ state: LevelDetector.State) {
        var text: String?
        var color = NSColor.systemOrange
        switch state {
        case .quiet where showHUD:
            let drop = Int((detector.dropAmount ?? dropDb).rounded())
            text = "You've gone quiet — speak up  (−\(drop) dB)"
        case .silent where showHUD && alertSilent:
            text = muted ? "Mic is muted in macOS" : "Mic is picking up nothing — muted or disconnected?"
            color = .systemRed
        default:
            break
        }
        if let text {
            if text != lastHudText || !hud.isVisible { hud.show(text, color: color) }
            lastHudText = text
            hudShowsAlert = true
        } else if hudShowsAlert {
            hudShowsAlert = false
            lastHudText = ""
            hud.hide()
        }
    }

    /// Brief informational message (device switched, volume changed…).
    private func notice(_ text: String) {
        guard showHUD, !hudShowsAlert else { return }
        hud.show(text, color: .systemBlue, duration: 4)
    }

    // MARK: UI

    private func refreshUI() {
        let target = min(max((detector.level + 60) / 50, 0), 1)   // -60…-10 dBFS
        displayLevel = target > displayLevel ? target : max(target, displayLevel - 0.08)
        renderStatusIcon()
        if menuOpen { refreshMenu() }
    }

    private func renderStatusIcon() {
        guard let button = statusItem?.button else { return }
        let state = effectiveState
        let alert = (state == .quiet || state == .silent) && !permissionDenied
        let color: NSColor = state == .quiet ? .systemOrange : .systemRed
        let level = CGFloat(displayLevel)
        let symbol = muted || permissionDenied ? "mic.slash.fill" : "mic.fill"

        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let tint: NSColor = alert ? color : .black
            if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mic Helper"),
               let sym = base.withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(paletteColors: [tint]))) {
                let s = sym.size
                sym.draw(in: NSRect(x: 0, y: (18 - s.height) / 2, width: s.width, height: s.height))
            }
            let track = NSRect(x: 16, y: 2, width: 4, height: 14)
            (alert ? color.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.25)).setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let fill = NSRect(x: 16, y: 2, width: 4, height: max(1, 14 * level))
            tint.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            return true
        }
        img.isTemplate = !alert   // template = follows light/dark menu bar automatically
        button.image = img

        if state == .quiet {
            button.attributedTitle = NSAttributedString(string: " Speak up", attributes: [
                .foregroundColor: NSColor.systemOrange, .font: NSFont.menuBarFont(ofSize: 0)])
        } else if !button.title.isEmpty {
            button.title = ""
        }
    }

    private func refreshMenu() {
        let d = detector
        if permissionDenied {
            graph.headline = "Microphone access needed"
            graph.subline = "Allow Mic Helper in Privacy & Security → Microphone"
        } else if let err = audioError {
            graph.headline = "Can't read the mic"
            graph.subline = err
        } else {
            switch effectiveState {
            case .calibrating: graph.headline = "Learning your normal level — just talk"
            case .ok: graph.headline = "Sounding normal"
            case .quiet: graph.headline = "You've gone quiet — speak up"
            case .silent: graph.headline = muted ? "Mic is muted" : "No signal from the mic"
            }
            var parts = ["Now \(Int(d.level.rounded())) dB"]
            if let s = d.shortTerm { parts.append("speaking \(Int(s.rounded())) dB") }
            if let b = d.baseline { parts.append("normal \(Int(b.rounded())) dB") }
            graph.subline = parts.joined(separator: " · ")
        }
        graph.needsDisplay = true
        deviceItem.title = "Mic: \(deviceName)"
        updateVolumeControls()
    }

    private func updateVolumeControls() {
        if let v = lastVolume {
            volumeSlider.isEnabled = true
            volumeSlider.floatValue = v
            volumeLabel.stringValue = "Input volume \(pct(v))"
        } else {
            volumeSlider.isEnabled = false
            volumeLabel.stringValue = "Input volume (not adjustable)"
        }
        lockItem?.state = lockVolume ? .on : .off
    }

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false

        let graphItem = NSMenuItem()
        graphItem.view = graph
        menu.addItem(graphItem)
        menu.addItem(.separator())

        deviceItem.isEnabled = false
        menu.addItem(deviceItem)

        let volView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 46))
        volumeLabel.frame = NSRect(x: 20, y: 26, width: 280, height: 16)
        volumeLabel.font = .menuFont(ofSize: 12)
        volumeLabel.textColor = .secondaryLabelColor
        volumeSlider.frame = NSRect(x: 18, y: 4, width: 284, height: 20)
        volumeSlider.target = self
        volumeSlider.action = #selector(sliderMoved(_:))
        volumeSlider.isContinuous = true
        volView.addSubview(volumeLabel)
        volView.addSubview(volumeSlider)
        volumeItem = NSMenuItem()
        volumeItem.view = volView
        menu.addItem(volumeItem)

        lockItem = item("Lock input volume (undo apps lowering it)", #selector(toggleLock))
        menu.addItem(.separator())

        let histItem = item("Show history graph…", #selector(showHistoryAction))
        histItem.keyEquivalent = "h"
        item("Open data folder (CSV)", #selector(openDataFolderAction))
        menu.addItem(.separator())
        item("Re-learn my normal level", #selector(recalibrate))
        let sens = NSMenuItem(title: "Alert when quieter by", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (db, label) in [(6.0, "6 dB (very sensitive)"), (8.0, "8 dB (default)"), (10.0, "10 dB"), (12.0, "12 dB (big drops only)")] {
            let it = NSMenuItem(title: label, action: #selector(setSensitivity(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = db
            it.state = db == dropDb ? .on : .off
            sub.addItem(it)
            sensitivityItems.append(it)
        }
        sens.submenu = sub
        menu.addItem(sens)

        hudItem = item("Show on-screen alert", #selector(toggleHUD))
        hudItem.state = showHUD ? .on : .off
        silentItem = item("Alert when the mic goes silent", #selector(toggleSilent))
        silentItem.state = alertSilent ? .on : .off
        soundItem = item("Play a sound when I go quiet", #selector(toggleSound))
        soundItem.state = playSound ? .on : .off

        menu.addItem(.separator())
        loginItem = item("Open at login", #selector(toggleLogin))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        privacyItem = item("Open Microphone privacy settings…", #selector(openPrivacy))
        privacyItem.isHidden = true
        item("Sound input settings…", #selector(openSoundSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Mic Helper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
        return it
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; refreshMenu() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    // MARK: Actions

    @objc private func sliderMoved(_ sender: NSSlider) {
        guard let id = device else { return }
        let v = sender.floatValue
        if lockVolume { defaults.set(v, forKey: "lockedVolume") }
        lastVolume = v   // set first so our own change doesn't trigger a notice
        CoreAudioDevice.setInputVolume(id, v)
        volumeLabel.stringValue = "Input volume \(pct(v))"
    }

    @objc private func toggleLock() {
        let on = !lockVolume
        defaults.set(on, forKey: "lockVolume")
        if on, let id = device, let v = CoreAudioDevice.inputVolume(id) {
            defaults.set(v, forKey: "lockedVolume")
        } else {
            defaults.removeObject(forKey: "lockedVolume")
        }
        updateVolumeControls()
    }

    @objc private func showHistoryAction() { showHistory() }
    @objc private func openDataFolderAction() { openDataFolder() }

    @objc private func recalibrate() {
        history.event("relearn_normal_level")
        detector.reset()
        notice("Re-learning your normal level — just talk normally")
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        guard let db = sender.representedObject as? Double else { return }
        dropDb = db
        sensitivityItems.forEach { $0.state = ($0.representedObject as? Double) == db ? .on : .off }
    }

    @objc private func toggleHUD() {
        defaults.set(!showHUD, forKey: "showHUD")
        hudItem.state = showHUD ? .on : .off
        if !showHUD { hud.hide(); hudShowsAlert = false }
    }

    @objc private func toggleSilent() {
        defaults.set(!alertSilent, forKey: "alertSilent")
        silentItem.state = alertSilent ? .on : .off
    }

    @objc private func toggleSound() {
        defaults.set(!playSound, forKey: "playSound")
        soundItem.state = playSound ? .on : .off
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Mic Helper to /Applications and try again, or add it in System Settings → General → Login Items."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        loginItem.state = svc.status == .enabled ? .on : .off
    }

    @objc private func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")!)
    }
}
