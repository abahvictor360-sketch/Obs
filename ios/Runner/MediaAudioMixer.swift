import AVFoundation
import Foundation

/// The sound of Media Sources (video files) in the stream: the audio track is
/// read again with AVAssetReader, kept in step with the player's position
/// (sent from Dart) and mixed after the microphone. Same contract as
/// android/.../MediaAudioMixer.kt.
final class MediaAudioMixer {
    static let shared = MediaAudioMixer()
    static let rate: Double = 44_100

    /// Per-source level (id, rms, peak) of what is mixed, for the meters.
    var onLevel: ((String, Float, Float) -> Void)?

    private let lock = NSLock()
    private var tracks: [String: Track] = [:]

    /// [list]: {id, path, gain, playing, positionMs, loop} per live media source.
    func update(_ list: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = Set(list.compactMap { $0["id"] as? String })
        for (id, t) in tracks where !wanted.contains(id) {
            t.close()
            tracks[id] = nil
        }
        for m in list {
            guard let id = m["id"] as? String, let path = m["path"] as? String else { continue }
            var t = tracks[id]
            if let existing = t, existing.path != path {
                existing.close()
                t = nil
            }
            if t == nil {
                t = Track(id: id, path: path)
                tracks[id] = t
            }
            t!.gain = Float((m["gain"] as? NSNumber)?.doubleValue ?? 1)
            t!.loop = (m["loop"] as? Bool) ?? true
            t!.sync(positionMs: Int64((m["positionMs"] as? NSNumber)?.int64Value ?? 0),
                    playing: (m["playing"] as? Bool) ?? false)
        }
    }

    /// Adds the playing tracks to mono samples (-1...1) and advances them.
    /// With mix false they only advance (meters while nothing is encoded).
    func mix(into samples: inout [Float], mix: Bool = true) {
        lock.lock()
        let active = tracks.values.filter { $0.playing }
        lock.unlock()
        guard !active.isEmpty else { return }
        let frames = samples.count
        var scratch = [Float](repeating: 0, count: frames * 2)
        for t in active {
            let got = t.read(into: &scratch, frames: frames)
            guard got > 0 else { continue }
            let g = t.gain
            var sum: Float = 0
            var peak: Float = 0
            for f in 0..<got {
                let v = (scratch[f * 2] + scratch[f * 2 + 1]) * 0.5 * g
                let a = abs(v)
                sum += a * a
                peak = max(peak, a)
                if mix { samples[f] = max(-1, min(1, samples[f] + v)) }
            }
            t.reportLevel(rms: (sum / Float(got)).squareRoot(), peak: min(peak, 1), frames: got) { [weak self] id, r, p in
                self?.onLevel?(id, r, p)
            }
        }
    }

    /// One media file's audio: a reader thread filling a small ring buffer.
    private final class Track {
        let id: String
        let path: String
        var gain: Float = 1
        var loop = true
        var playing = false

        private let cond = NSCondition()
        private var ring = [Float](repeating: 0, count: Int(MediaAudioMixer.rate) * 2 * 2) // 2 s stereo
        private var readAt = 0
        private var writeAt = 0
        private var buffered = 0
        private var readPosUs: Int64 = 0
        private var seekToUs: Int64 = -1
        private var durationUs: Int64 = 0
        private var alive = true
        private var levelSum: Float = 0
        private var levelPeak: Float = 0
        private var levelFrames = 0

        init(id: String, path: String) {
            self.id = id
            self.path = path
            let thread = Thread { [weak self] in self?.readLoop() }
            thread.name = "obs-media-audio"
            thread.start()
        }

        func close() {
            cond.lock()
            alive = false
            cond.broadcast()
            cond.unlock()
        }

        func sync(positionMs: Int64, playing isPlaying: Bool) {
            cond.lock()
            playing = isPlaying
            let cur = loop && durationUs > 0 ? (readPosUs % durationUs) / 1000 : readPosUs / 1000
            var drift = abs(cur - positionMs)
            if loop && durationUs > 0 { drift = min(drift, durationUs / 1000 - drift) }
            if seekToUs < 0 && drift > 500 {
                seekToUs = positionMs * 1000
                buffered = 0
                readAt = 0
                writeAt = 0
                readPosUs = seekToUs
            }
            cond.broadcast()
            cond.unlock()
        }

        func read(into out: inout [Float], frames: Int) -> Int {
            cond.lock()
            defer { cond.unlock() }
            let n = min(frames, buffered / 2)
            for i in 0..<(n * 2) {
                out[i] = ring[readAt]
                readAt = (readAt + 1) % ring.count
            }
            buffered -= n * 2
            readPosUs += Int64(n) * 1_000_000 / Int64(MediaAudioMixer.rate)
            cond.broadcast()
            return n
        }

        func reportLevel(rms: Float, peak: Float, frames: Int, emit: (String, Float, Float) -> Void) {
            levelSum += rms * rms * Float(frames)
            levelPeak = max(levelPeak, peak)
            levelFrames += frames
            if levelFrames >= Int(MediaAudioMixer.rate) / 20 {
                emit(id, (levelSum / Float(levelFrames)).squareRoot(), levelPeak)
                levelSum = 0
                levelPeak = 0
                levelFrames = 0
            }
        }

        /// Writes stereo samples; false if a seek or close interrupted it.
        private func write(_ stereo: UnsafeBufferPointer<Float>) -> Bool {
            cond.lock()
            defer { cond.unlock() }
            var i = 0
            while i < stereo.count {
                while buffered >= ring.count - 2 && alive && seekToUs < 0 { cond.wait(until: Date().addingTimeInterval(0.05)) }
                if !alive || seekToUs >= 0 { return false }
                ring[writeAt] = stereo[i]
                writeAt = (writeAt + 1) % ring.count
                buffered += 1
                i += 1
            }
            return true
        }

        private func readLoop() {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            guard let track = asset.tracks(withMediaType: .audio).first else { return }
            durationUs = Int64(CMTimeGetSeconds(asset.duration) * 1_000_000)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: MediaAudioMixer.rate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            var startUs: Int64 = 0
            while true {
                cond.lock()
                if !alive { cond.unlock(); return }
                if seekToUs >= 0 {
                    startUs = seekToUs
                    seekToUs = -1
                }
                cond.unlock()

                guard let reader = try? AVAssetReader(asset: asset) else { return }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                reader.timeRange = CMTimeRange(start: CMTime(value: startUs, timescale: 1_000_000), duration: .positiveInfinity)
                guard reader.startReading() else { return }
                var interrupted = false
                while let sample = output.copyNextSampleBuffer() {
                    guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                    // Copied out: the block buffer may be split into several pieces.
                    let length = CMBlockBufferGetDataLength(block)
                    var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                    let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                        guard let base = raw.baseAddress else { return -1 }
                        return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
                    }
                    guard status == noErr else { continue }
                    let ok = data.withUnsafeBufferPointer { write($0) }
                    if !ok {
                        interrupted = true
                        break
                    }
                }
                reader.cancelReading()
                if interrupted { continue } // seek or close
                // End of file: loop from the start, or wait for a restart.
                cond.lock()
                if loop {
                    startUs = 0
                } else {
                    while alive && seekToUs < 0 { cond.wait(until: Date().addingTimeInterval(0.2)) }
                }
                cond.unlock()
            }
        }
    }
}
