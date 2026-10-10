import Foundation

/// Sound that arrives live from the network (NDI and RTMP input sources):
/// Dart pushes PCM as it comes, and it's mixed into the stream after the
/// media sources. Each track keeps a small buffer against network jitter,
/// plus the source's audio sync offset. Same contract as
/// android/.../LiveAudio.kt.
final class LiveAudio {
    static let shared = LiveAudio()
    static let rate = MediaAudioMixer.rate
    private static let jitterMs = 80.0
    private static let slackMs = 250.0

    var onLevel: ((String, Float, Float) -> Void)?

    private let lock = NSLock()
    private var tracks: [String: Track] = [:]

    /// [list]: {id, gain, delayMs} for each live source on Program.
    func update(_ list: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(list.compactMap { $0["id"] as? String })
        for id in tracks.keys where !wanted.contains(id) { tracks[id] = nil }
        for m in list {
            guard let id = m["id"] as? String else { continue }
            let t = tracks[id] ?? Track(id: id)
            tracks[id] = t
            t.gain = Float((m["gain"] as? NSNumber)?.doubleValue ?? 1)
            t.setDelay(ms: (m["delayMs"] as? NSNumber)?.intValue ?? 0)
        }
    }

    /// Interleaved float PCM ([channels] 1 or 2) at [rate] for source [id].
    func push(id: String, pcm: [Float], channels: Int, rate: Double) {
        lock.lock()
        let t = tracks[id]
        lock.unlock()
        t?.write(pcm, channels: channels, rate: rate)
    }

    private func active() -> [Track] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tracks.values)
    }

    /// Adds the live tracks in stereo to [left]/[right] (same length).
    func mixStereo(left: inout [Float], right: inout [Float]) {
        let list = active()
        guard !list.isEmpty else { return }
        let frames = left.count
        var scratch = [Float](repeating: 0, count: frames * 2)
        for t in list {
            let got = t.read(into: &scratch, frames: frames)
            var sum: Float = 0
            var peak: Float = 0
            for f in 0..<got {
                let l = scratch[f * 2] * t.gain, r = scratch[f * 2 + 1] * t.gain
                left[f] += l
                right[f] += r
                let a = max(abs(l), abs(r))
                sum += a * a
                peak = max(peak, a)
            }
            report(t, sum: sum, peak: peak, frames: got == 0 ? frames : got)
        }
    }

    /// Adds the live tracks to mono samples; with [mix] false they only advance.
    func mix(into samples: inout [Float], mix: Bool = true) {
        let list = active()
        guard !list.isEmpty else { return }
        let frames = samples.count
        var scratch = [Float](repeating: 0, count: frames * 2)
        for t in list {
            let got = t.read(into: &scratch, frames: frames)
            var sum: Float = 0
            var peak: Float = 0
            for f in 0..<got {
                let v = (scratch[f * 2] + scratch[f * 2 + 1]) * 0.5 * t.gain
                let a = abs(v)
                sum += a * a
                peak = max(peak, a)
                if mix { samples[f] = max(-1, min(1, samples[f] + v)) }
            }
            report(t, sum: sum, peak: peak, frames: got == 0 ? frames : got)
        }
    }

    private func report(_ t: Track, sum: Float, peak: Float, frames: Int) {
        t.levelSum += sum
        t.levelPeak = max(t.levelPeak, peak)
        t.levelFrames += frames
        if t.levelFrames >= Int(LiveAudio.rate) / 20 {
            onLevel?(t.id, (t.levelSum / Float(t.levelFrames)).squareRoot(), min(t.levelPeak, 1))
            t.levelSum = 0
            t.levelPeak = 0
            t.levelFrames = 0
        }
    }

    private final class Track {
        let id: String
        var gain: Float = 1
        var levelSum: Float = 0
        var levelPeak: Float = 0
        var levelFrames = 0

        private let lock = NSLock()
        private var ring = [Float](repeating: 0, count: Int(LiveAudio.rate) * 2 * 4) // 4 s stereo
        private var readAt = 0
        private var writeAt = 0
        private var buffered = 0 // stereo frames
        private var targetFrames = Int(LiveAudio.rate * LiveAudio.jitterMs / 1000)
        private var priming = true
        private var resamplePos = 0.0
        private var lastL: Float = 0
        private var lastR: Float = 0

        init(id: String) { self.id = id }

        func setDelay(ms: Int) {
            let t = Int(LiveAudio.rate * (LiveAudio.jitterMs + Double(min(max(ms, 0), 2000))) / 1000)
            lock.lock()
            if t != targetFrames {
                targetFrames = t
                priming = buffered < t
            }
            lock.unlock()
        }

        func write(_ pcm: [Float], channels: Int, rate: Double) {
            guard channels >= 1, rate > 0 else { return }
            let inFrames = pcm.count / channels
            let step = rate / LiveAudio.rate
            lock.lock()
            defer { lock.unlock() }
            var pos = resamplePos
            while pos < Double(inFrames) {
                let i = Int(pos)
                let frac = Float(pos - Double(i))
                let l0 = i == 0 ? lastL : pcm[(i - 1) * channels]
                let r0 = i == 0 ? lastR : pcm[(i - 1) * channels + (channels - 1)]
                let l1 = pcm[i * channels]
                let r1 = pcm[i * channels + (channels - 1)]
                put(l0 + (l1 - l0) * frac, r0 + (r1 - r0) * frac)
                pos += step
            }
            resamplePos = pos - Double(inFrames)
            if inFrames > 0 {
                lastL = pcm[(inFrames - 1) * channels]
                lastR = pcm[(inFrames - 1) * channels + (channels - 1)]
            }
            let maxFrames = targetFrames + Int(LiveAudio.rate * LiveAudio.slackMs / 1000)
            if buffered > maxFrames {
                let drop = buffered - targetFrames
                readAt = (readAt + drop * 2) % ring.count
                buffered -= drop
            }
        }

        private func put(_ l: Float, _ r: Float) {
            if buffered >= ring.count / 2 {
                readAt = (readAt + 2) % ring.count
                buffered -= 1
            }
            ring[writeAt] = l
            ring[(writeAt + 1) % ring.count] = r
            writeAt = (writeAt + 2) % ring.count
            buffered += 1
        }

        func read(into out: inout [Float], frames: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if priming {
                if buffered < targetFrames { return 0 }
                priming = false
            }
            let n = min(frames, buffered)
            for i in 0..<(n * 2) {
                out[i] = ring[readAt]
                readAt = (readAt + 1) % ring.count
            }
            buffered -= n
            if n < frames { priming = true }
            return n
        }
    }
}

/// A fixed delay for one mono signal (a mic's audio sync offset).
final class DelayLine {
    private let sampleRate: Double
    private var buf: [Float] = []
    private var at = 0

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    func process(_ samples: inout [Float], delayMs: Int) {
        let d = Int(sampleRate * Double(min(max(delayMs, 0), 2000)) / 1000)
        if d != buf.count {
            buf = [Float](repeating: 0, count: d)
            at = 0
        }
        if d == 0 { return }
        for i in 0..<samples.count {
            let out = buf[at]
            buf[at] = samples[i]
            samples[i] = out
            at = (at + 1) % d
        }
    }
}
