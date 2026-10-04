import AVFoundation

/// Listens to the microphone while nothing is being streamed or recorded so
/// the mixer meter moves like OBS's. Nothing is encoded or stored;
/// AppAudioEncoder takes over the microphone (and the meter) when an output
/// starts.
final class MicMeter {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var _gain: Float = 1
    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = newValue; lock.unlock() }
    }

    private let onLevel: (_ rms: Float, _ peak: Float) -> Void
    private var processor: MicProcessor?

    init(onLevel: @escaping (_ rms: Float, _ peak: Float) -> Void) {
        self.onLevel = onLevel
    }

    func start() throws {
        AudioRouting.apply() // USB / Bluetooth / chosen microphone
        MicProcessing.applyVoiceProcessing(engine) // Noise Suppression filter
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        processor = MicProcessor(sampleRate: format.sampleRate)
        // About 50 ms per reading, the same rate as the encoder's levels.
        let size = AVAudioFrameCount(max(1024, format.sampleRate / 20))
        input.installTap(onBus: 0, bufferSize: size, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0, 0)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        guard n > 0, chCount > 0 else { return }
        let g = gain / Float(chCount)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v: Float = 0
            for c in 0..<chCount { v += channels[c][i] }
            mono[i] = v * g
        }
        processor?.process(&mono) // the meter shows the filtered mic
        var sum: Float = 0
        var peak: Float = 0
        for v in mono {
            let a = min(abs(v), 1)
            sum += a * a
            peak = max(peak, a)
        }
        onLevel(sqrt(sum / Float(n)), peak)
    }
}
