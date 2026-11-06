import AVFoundation
import Accelerate

/// Taps the default input device and reports the RMS level (dBFS) of each
/// buffer on the main queue. Uses the raw signal — no voice processing / AGC.
final class AudioMonitor {
    var onLevel: ((_ db: Double, _ dt: Double) -> Void)?
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
            var best: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                var sumSq: Float = 0
                vDSP_svesq(data[c], 1, &sumSq, vDSP_Length(n))
                best = max(best, sumSq)
            }
            let rms = sqrt(Double(best) / Double(n))
            let db = 20 * log10(max(rms, 1e-7))
            let dt = Double(n) / buffer.format.sampleRate
            DispatchQueue.main.async { self?.onLevel?(db, dt) }
        }

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }

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
