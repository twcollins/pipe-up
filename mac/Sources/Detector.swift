import Foundation

/// Watches a stream of mic levels (dBFS) and decides whether the speaker has
/// become noticeably quieter than their own normal speaking level.
///
/// How it works:
///  * A noise floor is tracked (falls quickly, rises slowly).
///  * A frame counts as "speech" when it is clearly above the noise floor.
///  * Two averages of speech frames are kept: a short one (~1.5 s of speech)
///    and a long baseline (~45 s of speech) that represents "normal you".
///  * If the short average sits `dropDb` below the baseline for `holdSeconds`
///    while you are speaking, the state becomes `.quiet`.
///  * If the signal is effectively digital silence for a few seconds, the state
///    becomes `.silent` (muted at the hardware / device gone / broken cable).
final class LevelDetector {
    enum State: Equatable {
        case calibrating   // still learning your normal level
        case ok
        case quiet         // speaking, but well below your normal level
        case silent        // no signal at all
    }

    struct Sample {
        var db: Double
        var speech: Double?   // short-term speech level when speaking, else nil
    }

    // Tunables
    var dropDb: Double = 8
    var holdSeconds: Double = 2.0
    var calibrationSpeechSeconds: Double = 8

    // Outputs
    private(set) var state: State = .calibrating
    private(set) var level: Double = -100
    private(set) var noiseFloor: Double = -60
    private(set) var baseline: Double?
    private(set) var shortTerm: Double?
    private(set) var history: [Sample] = []

    // Diagnostics: what the background and your voice's "brightness" (treble
    // relative to overall level) looked like when your normal level was learnt.
    private(set) var baselineNoiseFloor: Double?
    private(set) var brightness: Double?          // short-term, speech only (dB)
    private(set) var baselineBrightness: Double?
    /// Seconds since the last pause (non-speech frame). The background-noise
    /// estimate is only trustworthy if there has been a recent pause.
    private(set) var sincePause: Double = .infinity
    let historyLength = 700   // ~60 s at ~85 ms per frame

    /// How far below baseline the current speech is (positive = quieter).
    var dropAmount: Double? {
        guard let b = baseline, let s = shortTerm else { return nil }
        return b - s
    }

    private var speechSeconds: Double = 0
    private var calibrationSum: Double = 0
    private var calibrationN: Double = 0
    private var sinceSpeech: Double = .infinity
    private var quietFor: Double = 0
    private var silentFor: Double = 0
    private var calibrationBright: Double = 0
    private var calibrationBrightN: Double = 0

    func reset() {
        state = .calibrating
        baseline = nil
        shortTerm = nil
        speechSeconds = 0
        calibrationSum = 0
        calibrationN = 0
        quietFor = 0
        silentFor = 0
        sinceSpeech = .infinity
        baselineNoiseFloor = nil
        brightness = nil
        baselineBrightness = nil
        calibrationBright = 0
        calibrationBrightN = 0
    }

    private func ema(_ old: Double, _ new: Double, dt: Double, tau: Double) -> Double {
        old + (new - old) * (1 - exp(-dt / tau))
    }

    /// - Parameter hfDb: level of the high-frequency part of the signal (dBFS),
    ///   used to spot a muffled / turned-away mic. Optional.
    func process(db: Double, hfDb: Double? = nil, dt: Double) {
        level = db

        // Noise floor: fast down, slow up (0.3 dB/s). Digital silence (muted /
        // dead mic) is ignored so it can't drag the floor down.
        if db < -100 {
            // leave noiseFloor alone
        } else if db < noiseFloor {
            noiseFloor = ema(noiseFloor, db, dt: dt, tau: 0.5)
        } else {
            noiseFloor += min(db - noiseFloor, 0.3 * dt)
        }
        noiseFloor = min(max(noiseFloor, -110), -35)

        let isSpeech = db > max(noiseFloor + 9, -70)

        if isSpeech {
            sinceSpeech = 0
            speechSeconds += dt
            shortTerm = shortTerm.map { ema($0, db, dt: dt, tau: 1.5) } ?? db
            let bright = hfDb.map { $0 - db }
            if let bright { brightness = brightness.map { ema($0, bright, dt: dt, tau: 1.5) } ?? bright }

            if baseline == nil {
                calibrationSum += db
                calibrationN += 1
                if let bright { calibrationBright += bright; calibrationBrightN += 1 }
                if speechSeconds >= calibrationSpeechSeconds {
                    baseline = calibrationSum / calibrationN
                    baselineNoiseFloor = noiseFloor
                    if calibrationBrightN > 0 { baselineBrightness = calibrationBright / calibrationBrightN }
                }
            } else if var b = baseline {
                // Adapt slowly; much more slowly while quiet so the baseline
                // doesn't simply follow you down.
                let tau = state == .quiet ? 400.0 : 45.0
                b = ema(b, db, dt: dt, tau: tau)
                baseline = b
                if let bright, let bb = baselineBrightness {
                    baselineBrightness = ema(bb, bright, dt: dt, tau: tau)
                }
            }
            sincePause += dt
        } else {
            sinceSpeech += dt
            if db >= -100 { sincePause = 0 }
        }

        // Silence: real mics always have some self-noise well above -100 dBFS.
        silentFor = db < -100 ? silentFor + dt : 0

        // Quiet detection.
        if let b = baseline, let s = shortTerm, sinceSpeech < 1.0 {
            let threshold = b - dropDb
            if s < threshold {
                quietFor += dt
            } else if s > threshold + 2 {   // hysteresis
                quietFor = 0
            }
        } else if sinceSpeech > 6 {
            quietFor = 0  // stopped talking — stop nagging
        }

        if silentFor > 3 {
            state = .silent
        } else if baseline == nil {
            state = .calibrating
        } else if quietFor >= holdSeconds {
            state = .quiet
        } else {
            state = .ok
        }

        // Track the "normal" background only while things are normal.
        if state == .ok, let nb = baselineNoiseFloor {
            baselineNoiseFloor = ema(nb, noiseFloor, dt: dt, tau: 120)
        }

        history.append(Sample(db: db, speech: isSpeech ? shortTerm : nil))
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
    }
}
