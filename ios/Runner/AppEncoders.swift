import AVFoundation
import CoreImage
import Foundation

/// Video encoder used while the app is in the foreground: plain frames from
/// Flutter, or the overlay layers with a black hole for the screen when the
/// broadcast extension isn't running. When the extension is capturing, it
/// does the compositing and this encoder is suspended.
final class AppVideoEncoder {
    let width: Int
    let height: Int
    private let fps: Int
    private let encoder: H264Encoder
    private let compositor: Compositor
    private let queue = DispatchQueue(label: "org.obstablet.video")

    // On `queue`:
    private var compositing = false
    private var under: CIImage?
    private var over: CIImage?
    private var placement: ScreenPlacement?
    private var timer: DispatchSourceTimer?
    private var suspended = false

    init(width: Int, height: Int, fps: Int, bitrate: Int, keyframeIntervalSec: Int,
         onOutput: @escaping (EncodedVideo) -> Void, onError: @escaping (String) -> Void) {
        self.width = width
        self.height = height
        self.fps = max(fps, 1)
        encoder = H264Encoder(width: width, height: height, fps: fps, bitrate: bitrate,
                              keyframeIntervalSec: keyframeIntervalSec)
        encoder.onOutput = onOutput
        encoder.onError = onError
        compositor = Compositor(width: width, height: height)
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            compositing = false
        }
        encoder.invalidate()
    }

    func requestKeyframe() { encoder.requestKeyframe() }

    /// While the extension encodes the screen, this encoder produces nothing.
    func setSuspended(_ value: Bool) {
        queue.async {
            self.suspended = value
            if !value { self.encoder.requestKeyframe() }
        }
    }

    func drawFrame(_ rgba: Data, width w: Int, height h: Int, done: @escaping () -> Void) {
        queue.async {
            defer { done() }
            if self.compositing {
                self.compositing = false
                self.timer?.cancel()
                self.timer = nil
            }
            guard !self.suspended, let img = Compositor.ciImage(rgba: rgba, width: w, height: h),
                  let pb = self.encoder.makePixelBuffer() else { return }
            self.compositor.render(to: pb, under: img, screen: nil, placement: nil, over: nil)
            self.encoder.encode(pb, ptsUs: hostNowUs())
        }
    }

    func setOverlays(_ update: OverlayUpdate, done: @escaping () -> Void) {
        let u = update.under.flatMap { Compositor.ciImage(rgba: $0, width: update.width, height: update.height) }
        let o = update.over.flatMap { Compositor.ciImage(rgba: $0, width: update.width, height: update.height) }
        queue.async {
            defer { done() }
            if let u = u { self.under = u }
            if let o = o {
                self.over = o
            } else if update.clearOver {
                self.over = nil
            }
            self.placement = update.placement
            if !self.compositing {
                self.compositing = true
                let t = DispatchSource.makeTimerSource(queue: self.queue)
                t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / self.fps))
                t.setEventHandler { [weak self] in self?.renderComposite() }
                t.resume()
                self.timer = t
            }
        }
    }

    private func renderComposite() {
        // No screen pixels here: the extension isn't connected. The hole
        // stays black, as in OBS when a capture source has no signal.
        guard !suspended, let pb = encoder.makePixelBuffer() else { return }
        compositor.render(to: pb, under: under, screen: nil, placement: placement, over: over)
        encoder.encode(pb, ptsUs: hostNowUs())
    }
}

/// Microphone (+ other apps' audio from the screen broadcast) -> AAC-LC
/// 44.1 kHz mono. Runs AVAudioEngine, which also keeps the app alive in the
/// background (UIBackgroundModes: audio) so streaming continues while the
/// user is in another app.
final class AppAudioEncoder {
    static let sampleRate: Double = 44_100
    static let frameSize = 1024
    /// Output channels: 1 (mono) or 2 (stereo).
    let channels: Int
    /// AudioSpecificConfig for AAC-LC, 44.1 kHz, mono or stereo.
    var asc: Data { Data([0x12, channels == 2 ? 0x10 : 0x08]) }

    private let engine = AVAudioEngine()
    private let pcmFormat: AVAudioFormat
    private var aacFormat: AVAudioFormat
    private let converter: AVAudioConverter

    private let lock = NSLock()
    private var _gain: Float = 1
    private var _appGain: Float = 1
    var gain: Float {
        get { lock.lock(); defer { lock.unlock() }; return _gain }
        set { lock.lock(); _gain = newValue; lock.unlock() }
    }
    var appGain: Float {
        get { lock.lock(); defer { lock.unlock() }; return _appGain }
        set { lock.lock(); _appGain = newValue; lock.unlock() }
    }

    var onPacket: ((_ aac: Data, _ ptsUs: Int64) -> Void)?
    var onPCM: ((_ buffer: AVAudioPCMBuffer, _ ptsUs: Int64) -> Void)?
    var onLevel: ((_ rms: Float, _ peak: Float) -> Void)?

    // Audio thread state.
    private let micBus = MicBus()
    private var resampler = LinearResampler(targetRate: sampleRate)
    private var pendingL: [Float] = []
    private var pendingR: [Float] = []
    private var appScratch = [Float](repeating: 0, count: 8192)
    private var baseUs: Int64 = -1
    private var samplesQueued: Int64 = 0
    private var packetsOut: Int64 = 0
    private var levelSum: Float = 0
    private var levelPeak: Float = 0
    private var levelCount = 0
    private var lastLevelUs: Int64 = 0

    init(bitrate: Int, channels: Int = 1) throws {
        self.channels = channels == 2 ? 2 : 1
        pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AppAudioEncoder.sampleRate,
                                  channels: AVAudioChannelCount(channels == 2 ? 2 : 1), interleaved: false)!
        var asbd = AudioStreamBasicDescription(
            mSampleRate: AppAudioEncoder.sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(MPEG4ObjectID.AAC_LC.rawValue),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AppAudioEncoder.frameSize),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels == 2 ? 2 : 1),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let aac = AVAudioFormat(streamDescription: &asbd),
              let conv = AVAudioConverter(from: pcmFormat, to: aac)
        else { throw NSError(domain: "obs", code: 1, userInfo: [NSLocalizedDescriptionKey: "AAC encoder unavailable"]) }
        aacFormat = aac
        converter = conv
        converter.bitRate = bitrate
    }

    private var observers: [NSObjectProtocol] = []

    func start() throws {
        try startEngine()
        if observers.isEmpty {
            // A microphone plugged in or out, Bluetooth, or a call stops the
            // engine; without this the stream would carry on with no audio.
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                            queue: .main) { [weak self] _ in self?.restartInput() })
            observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.ended.rawValue {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self?.restartInput()
                }
            })
        }
    }

    private func startEngine() throws {
        AudioRouting.apply() // USB / chosen microphone
        MicProcessing.applyVoiceProcessing(engine) // Noise Suppression filter
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            self?.process(buffer, when)
        }
        engine.prepare()
        try engine.start()
    }

    /// Noise Suppression turned on/off: voice processing can only change
    /// while the engine is stopped, so restart the input (a short gap).
    func restartInput() {
        guard !stopped else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? startEngine()
    }

    private var stopped = false

    func stop() {
        stopped = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func process(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        guard buffer.floatChannelData != nil, buffer.frameLength > 0, buffer.format.channelCount > 0 else { return }
        let hostUs = when.isHostTimeValid
            ? Int64(AVAudioTime.seconds(forHostTime: when.hostTime) * 1_000_000)
            : hostNowUs()
        if baseUs < 0 {
            baseUs = hostUs
        } else {
            // After a gap (input restarted for Noise Suppression, route change,
            // interruption) move the timeline forward so audio stays in sync
            // with video instead of being stamped early by the gap.
            let expected = baseUs + samplesQueued * 1_000_000 / Int64(AppAudioEncoder.sampleRate)
            if hostUs - expected > 100_000 { baseUs += hostUs - expected }
        }

        // Mics: each input's channel, filters, then fader (like OBS), centred.
        let bus = micBus.mix(buffer)
        var mic = resampler.process(bus, sourceRate: buffer.format.sampleRate)
        let count = mic.count
        for v in mic {
            let a = min(abs(v), 1)
            levelSum += a * a
            levelPeak = max(levelPeak, a)
        }
        levelCount += count
        if appScratch.count < count { appScratch = [Float](repeating: 0, count: count) }
        let got = ScreenReceiver.shared.appAudio.read(into: &appScratch, count)
        let ag = appGain
        if got > 0 {
            for i in 0..<count { mic[i] += appScratch[i] * ag }
        }
        // Media Sources (video files) on Program keep their left/right.
        var left = mic
        var right = mic
        if channels == 2 {
            MediaAudioMixer.shared.mixStereo(left: &left, right: &right)
        } else {
            MediaAudioMixer.shared.mix(into: &left)
        }
        for i in 0..<count {
            left[i] = max(-1, min(1, left[i]))
            right[i] = max(-1, min(1, right[i]))
        }

        let nowUs = baseUs + samplesQueued * 1_000_000 / Int64(AppAudioEncoder.sampleRate)
        if nowUs - lastLevelUs > 50_000 {
            onLevel?(sqrt(levelSum / Float(max(levelCount, 1))), levelPeak)
            levelSum = 0
            levelPeak = 0
            levelCount = 0
            lastLevelUs = nowUs
        }

        pendingL.append(contentsOf: left)
        if channels == 2 { pendingR.append(contentsOf: right) }
        while pendingL.count >= AppAudioEncoder.frameSize {
            let l = Array(pendingL[0..<AppAudioEncoder.frameSize])
            pendingL.removeFirst(AppAudioEncoder.frameSize)
            var r: [Float]? = nil
            if channels == 2 {
                r = Array(pendingR[0..<AppAudioEncoder.frameSize])
                pendingR.removeFirst(AppAudioEncoder.frameSize)
            }
            encode(l, r)
        }
    }

    private func encode(_ chunk: [Float], _ right: [Float]?) {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        pcm.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { src in
            pcm.floatChannelData![0].update(from: src.baseAddress!, count: chunk.count)
        }
        if let r = right, channels == 2 {
            r.withUnsafeBufferPointer { src in
                pcm.floatChannelData![1].update(from: src.baseAddress!, count: r.count)
            }
        }
        let ptsUs = baseUs + samplesQueued * 1_000_000 / Int64(AppAudioEncoder.sampleRate)
        samplesQueued += Int64(chunk.count)
        onPCM?(pcm, ptsUs)

        let out = AVAudioCompressedBuffer(
            format: aacFormat, packetCapacity: 4, maximumPacketSize: max(converter.maximumOutputPacketSize, 1536)
        )
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, let descs = out.packetDescriptions else { return }
        for i in 0..<Int(out.packetCount) {
            let d = descs[i]
            let data = Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize))
            let pts = baseUs + packetsOut * Int64(AppAudioEncoder.frameSize) * 1_000_000 / Int64(AppAudioEncoder.sampleRate)
            packetsOut += 1
            onPacket?(data, pts)
        }
    }
}
