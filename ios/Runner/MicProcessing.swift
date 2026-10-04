import AVFoundation
import Foundation

/// The microphone's audio filters (Noise Suppression, Noise Gate, Compressor,
/// Limiter), set from Dart with "setMicProcessing". Same behaviour as
/// android/.../MicProcessing.kt.
final class MicProcessing {
    static let shared = MicProcessing()

    enum Stage {
        case gate(closeDb: Float, openDb: Float, attackMs: Float, holdMs: Float, releaseMs: Float)
        case compressor(ratio: Float, thresholdDb: Float, attackMs: Float, releaseMs: Float, outputDb: Float)
    }

    private let lock = NSLock()
    private var _chain: [Stage] = []
    private var _version = 0
    private(set) var noiseSuppression = false

    /// Called on the main thread when Noise Suppression is turned on or off
    /// (the audio engine restarts with voice processing).
    var onNoiseSuppressionChange: (() -> Void)?

    var snapshot: (chain: [Stage], version: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_chain, _version)
    }

    func configure(_ args: [String: Any]) {
        func f(_ m: [String: Any], _ k: String, _ def: Double) -> Float { Float((m[k] as? NSNumber)?.doubleValue ?? def) }
        var chain: [Stage] = []
        for case let m as [String: Any] in (args["chain"] as? [Any] ?? []) {
            switch m["type"] as? String {
            case "gate":
                chain.append(.gate(closeDb: f(m, "closeDb", -32), openDb: f(m, "openDb", -26), attackMs: f(m, "attackMs", 25),
                                   holdMs: f(m, "holdMs", 200), releaseMs: f(m, "releaseMs", 150)))
            case "compressor":
                chain.append(.compressor(ratio: f(m, "ratio", 10), thresholdDb: f(m, "thresholdDb", -18), attackMs: f(m, "attackMs", 6),
                                         releaseMs: f(m, "releaseMs", 60), outputDb: f(m, "outputDb", 0)))
            case "limiter":
                chain.append(.compressor(ratio: 1000, thresholdDb: f(m, "thresholdDb", -6), attackMs: 0.1,
                                         releaseMs: f(m, "releaseMs", 60), outputDb: 0))
            default:
                break
            }
        }
        lock.lock()
        _chain = chain
        _version += 1
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

/// Per-recording state for the chain (envelopes, gate state).
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

    /// Processes mono float samples (-1...1) in place.
    func process(_ samples: inout [Float]) {
        let snap = MicProcessing.shared.snapshot
        if snap.chain.isEmpty { return }
        if snap.version != version {
            version = snap.version
            stages = snap.chain
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
                }
            }
            rel = stages.map {
                switch $0 {
                case let .gate(_, _, _, _, r): return coef(r)
                case let .compressor(_, _, _, r, _): return coef(r)
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
                }
            }
            if gain != 1 { samples[s] = max(-1, min(1, samples[s] * gain)) }
        }
    }
}
