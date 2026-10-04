import AVFoundation
import Foundation

/// The microphones: one or more Mic/Aux sources, each taking a channel of the
/// audio device (both, input 1 / left, input 2 / right of a USB interface)
/// with its own filters (Noise Gate, Compressor, Limiter, Gain) and fader.
/// Noise Suppression applies to the device. Set from Dart with
/// "setMicProcessing". Same behaviour as android/.../MicProcessing.kt.
final class MicProcessing {
    static let shared = MicProcessing()

    enum Stage {
        case gate(closeDb: Float, openDb: Float, attackMs: Float, holdMs: Float, releaseMs: Float)
        case compressor(ratio: Float, thresholdDb: Float, attackMs: Float, releaseMs: Float, outputDb: Float)
        case gain(db: Float)
    }

    /// One Mic/Aux source: channel "mix", "left" or "right"; gain = fader × mute.
    struct Input {
        let id: String
        let channel: String
        let gain: Float
        let chain: [Stage]
        let version: Int
    }

    private let lock = NSLock()
    private var _inputs: [Input] = [Input(id: "", channel: "mix", gain: 1, chain: [], version: 0)]
    private var _version = 0
    private(set) var noiseSuppression = false

    /// Called on the main thread when Noise Suppression is turned on or off
    /// (the audio engine restarts with voice processing).
    var onNoiseSuppressionChange: (() -> Void)?

    /// Each Mic/Aux source's level (id, rms, peak), for its mixer meter.
    var onInputLevel: ((String, Float, Float) -> Void)?

    var inputs: [Input] {
        lock.lock(); defer { lock.unlock() }
        return _inputs
    }

    private static func parseChain(_ list: [Any]?) -> [Stage] {
        func f(_ m: [String: Any], _ k: String, _ def: Double) -> Float { Float((m[k] as? NSNumber)?.doubleValue ?? def) }
        var chain: [Stage] = []
        for case let m as [String: Any] in (list ?? []) {
            switch m["type"] as? String {
            case "gate":
                chain.append(.gate(closeDb: f(m, "closeDb", -32), openDb: f(m, "openDb", -26), attackMs: f(m, "attackMs", 25),
                                   holdMs: f(m, "holdMs", 200), releaseMs: f(m, "releaseMs", 150)))
            case "compressor":
                chain.append(.compressor(ratio: f(m, "ratio", 10), thresholdDb: f(m, "thresholdDb", -18), attackMs: f(m, "attackMs", 6),
                                         releaseMs: f(m, "releaseMs", 60), outputDb: f(m, "outputDb", 0)))
            case "limiter":
                // A compressor with an (almost) infinite ratio and instant attack.
                chain.append(.compressor(ratio: 1000, thresholdDb: f(m, "thresholdDb", -6), attackMs: 0,
                                         releaseMs: f(m, "releaseMs", 60), outputDb: 0))
            case "gain":
                chain.append(.gain(db: f(m, "db", 0)))
            default:
                break
            }
        }
        return chain
    }

    func configure(_ args: [String: Any]) {
        lock.lock()
        _version += 1
        let v = _version
        if let list = args["inputs"] as? [Any] {
            _inputs = list.compactMap { raw -> Input? in
                guard let m = raw as? [String: Any] else { return nil }
                return Input(id: m["id"] as? String ?? "",
                             channel: m["channel"] as? String ?? "mix",
                             gain: Float((m["gain"] as? NSNumber)?.doubleValue ?? 1),
                             chain: MicProcessing.parseChain(m["chain"] as? [Any]),
                             version: v)
            }
        } else {
            _inputs = [Input(id: "", channel: "mix", gain: _inputs.first?.gain ?? 1,
                             chain: MicProcessing.parseChain(args["chain"] as? [Any]), version: v)]
        }
        lock.unlock()
        let ns = (args["noiseSuppression"] as? Bool) ?? false
        if ns != noiseSuppression {
            noiseSuppression = ns
            onNoiseSuppressionChange?()
        }
    }

    /// Turns the input node's voice processing (Apple's noise suppression)
    /// on or off. The engine must be stopped.
    static func applyVoiceProcessing(_ engine: AVAudioEngine) {
        let on = MicProcessing.shared.noiseSuppression
        if engine.inputNode.isVoiceProcessingEnabled != on {
            try? engine.inputNode.setVoiceProcessingEnabled(on)
        }
    }
}

/// Mixes the microphone inputs of a captured buffer into one mono bus: each
/// input takes its channel, runs its filters, then its fader, and reports
/// its level.
final class MicBus {
    private var processors: [String: MicProcessor] = [:]
    private var sums: [String: (sum: Float, peak: Float, frames: Int)] = [:]

    func mix(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let n = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        var out = [Float](repeating: 0, count: n)
        guard n > 0, chCount > 0 else { return out }
        let inputs = MicProcessing.shared.inputs
        var tmp = [Float](repeating: 0, count: n)
        for input in inputs {
            let ch: Int
            switch input.channel {
            case "left": ch = 0
            case "right": ch = chCount > 1 ? 1 : 0
            default: ch = -1
            }
            if ch >= 0 {
                let p = channels[ch]
                for i in 0..<n { tmp[i] = p[i] }
            } else {
                let k = 1 / Float(chCount)
                for i in 0..<n {
                    var v: Float = 0
                    for c in 0..<chCount { v += channels[c][i] }
                    tmp[i] = v * k
                }
            }
            let proc: MicProcessor
            if let existing = processors[input.id] {
                proc = existing
            } else {
                proc = MicProcessor(sampleRate: rate)
                processors[input.id] = proc
            }
            proc.process(&tmp, chain: input.chain, version: input.version)
            let g = input.gain
            var acc = sums[input.id] ?? (0, 0, 0)
            for i in 0..<n {
                let v = tmp[i] * g
                out[i] += v
                let a = abs(v)
                acc.sum += a * a
                acc.peak = max(acc.peak, a)
            }
            acc.frames += n
            if acc.frames >= Int(rate) / 20 {
                MicProcessing.shared.onInputLevel?(input.id, (acc.sum / Float(acc.frames)).squareRoot(), min(acc.peak, 1))
                acc = (0, 0, 0)
            }
            sums[input.id] = acc
        }
        if processors.count > inputs.count {
            let ids = Set(inputs.map { $0.id })
            processors = processors.filter { ids.contains($0.key) }
        }
        return out
    }
}

/// Per-input state for a filter chain (envelopes, gate state).
final class MicProcessor {
    private let sampleRate: Float
    private var version = -1
    private var stages: [MicProcessing.Stage] = []
    private var gateEnv: [Float] = []
    private var gateGain: [Float] = []
    private var gateHeld: [Float] = []
    private var gateOpen: [Bool] = []
    private var compEnvDb: [Float] = []
    private var atk: [Float] = []
    private var rel: [Float] = []
    private let envFall: Float

    init(sampleRate: Double) {
        self.sampleRate = Float(sampleRate)
        envFall = exp(-1 / (0.010 * Float(sampleRate)))
    }

    private func coef(_ ms: Float) -> Float { ms <= 0 ? 0 : exp(-1 / (ms / 1000 * sampleRate)) }
    private func db(_ x: Float) -> Float { x <= 1e-6 ? -120 : 20 * log10(x) }

    /// Processes mono samples (-1...1) in place.
    func process(_ samples: inout [Float], chain: [MicProcessing.Stage], version v: Int) {
        if chain.isEmpty { return }
        if v != version {
            version = v
            stages = chain
            let n = stages.count
            gateEnv = [Float](repeating: 0, count: n)
            gateGain = [Float](repeating: 1, count: n)
            gateHeld = [Float](repeating: 0, count: n)
            gateOpen = [Bool](repeating: true, count: n)
            compEnvDb = [Float](repeating: -120, count: n)
            atk = stages.map {
                switch $0 {
                case let .gate(_, _, a, _, _): return coef(a)
                case let .compressor(_, _, a, _, _): return coef(a)
                case .gain: return 0
                }
            }
            rel = stages.map {
                switch $0 {
                case let .gate(_, _, _, _, r): return coef(r)
                case let .compressor(_, _, _, r, _): return coef(r)
                case .gain: return 0
                }
            }
        }
        let msPerSample = 1000 / sampleRate
        for s in 0..<samples.count {
            let peak = abs(samples[s])
            var gain: Float = 1
            for i in 0..<stages.count {
                let level = peak * gain
                switch stages[i] {
                case let .gate(closeDb, openDb, _, holdMs, _):
                    gateEnv[i] = max(level, gateEnv[i] * envFall)
                    let envDb = db(gateEnv[i])
                    if envDb >= openDb {
                        gateOpen[i] = true
                        gateHeld[i] = 0
                    } else if envDb < closeDb && gateOpen[i] {
                        gateHeld[i] += msPerSample
                        if gateHeld[i] >= holdMs { gateOpen[i] = false }
                    }
                    let target: Float = gateOpen[i] ? 1 : 0
                    let k = target > gateGain[i] ? atk[i] : rel[i]
                    gateGain[i] = target + (gateGain[i] - target) * k
                    gain *= gateGain[i]
                case let .compressor(ratio, thresholdDb, _, _, outputDb):
                    let inDb = db(level)
                    let k = inDb > compEnvDb[i] ? atk[i] : rel[i]
                    compEnvDb[i] = inDb + (compEnvDb[i] - inDb) * k
                    let over = compEnvDb[i] - thresholdDb
                    let reduction = over > 0 ? over * (1 - 1 / ratio) : 0
                    gain *= pow(10, (outputDb - reduction) / 20)
                case let .gain(gdb):
                    gain *= pow(10, gdb / 20)
                }
            }
            if gain != 1 { samples[s] = max(-1, min(1, samples[s] * gain)) }
        }
    }
}
