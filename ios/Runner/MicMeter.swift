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

    private var observer: NSObjectProtocol?

    func start() throws {
        try startEngine()
        // A mic plugged in or out stops the engine: start it again.
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
            try? self.startEngine()
        }
    }

    private func startEngine() throws {
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
        if let o = observer { NotificationCenter.default.removeObserver(o) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        onLevel(0, 0)
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        guard n > 0, chCount > 0 else { return }
        let k = 1 / Float(chCount)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v: Float = 0
            for c in 0..<chCount { v += channels[c][i] }
            mono[i] = v * k
        }
        // Media Sources advance (in real time) so their meters move while
        // nothing is encoded; they aren't part of the mic level.
        let mediaFrames = Int(Double(n) * MediaAudioMixer.rate / buffer.format.sampleRate)
        if mediaFrames > 0 {
            var media = [Float](repeating: 0, count: mediaFrames)
            MediaAudioMixer.shared.mix(into: &media, mix: false)
        }
        // Filters first, then the fader, like OBS.
        processor?.process(&mono)
        let g = gain
        for i in 0..<n { mono[i] *= g }
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
