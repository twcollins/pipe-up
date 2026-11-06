import AVFoundation
import Accelerate

/// Taps the default input device and reports the RMS level (dBFS) of each
/// buffer on the main queue. Uses the raw signal — no voice processing / AGC.
final class AudioMonitor {
    /// db = overall RMS level, hfDb = level of the high-frequency content
    /// (first-difference of the signal), both dBFS.
    var onLevel: ((_ db: Double, _ hfDb: Double, _ dt: Double) -> Void)?
    private(set) var sampleRate: Double = 0
    private(set) var channelCount: Int = 0
    var onConfigurationChange: (() -> Void)?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "PipeUp", code: 1, userInfo: [NSLocalizedDescriptionKey: "No input device available"])
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            // Use the loudest channel: multi-channel interfaces often carry the
            // mic on only one channel.
            var best: Float = 0, bestCh = 0
            for c in 0..<Int(buffer.format.channelCount) {
                var sumSq: Float = 0
                vDSP_svesq(data[c], 1, &sumSq, vDSP_Length(n))
                if sumSq > best { best = sumSq; bestCh = c }
            }
            let rms = sqrt(Double(best) / Double(n))
            let db = 20 * log10(max(rms, 1e-7))

            // High-frequency content: x[i+1] - x[i] boosts treble ~6 dB/octave.
            var hfDb = -140.0
            if n > 1 {
                var diff = [Float](repeating: 0, count: n - 1)
                let x = data[bestCh]
                vDSP_vsub(x, 1, x + 1, 1, &diff, 1, vDSP_Length(n - 1))
                var hfSq: Float = 0
                vDSP_svesq(diff, 1, &hfSq, vDSP_Length(n - 1))
                hfDb = 20 * log10(max(sqrt(Double(hfSq) / Double(n - 1)), 1e-7))
            }
            let dt = Double(n) / buffer.format.sampleRate
            DispatchQueue.main.async { self?.onLevel?(db, hfDb, dt) }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }

        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }
}
