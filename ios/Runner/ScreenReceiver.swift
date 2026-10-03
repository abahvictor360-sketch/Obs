import Foundation

/// App side of the link to the broadcast extension: a Unix socket server in
/// the App Group container. Receives encoded screen video and other apps'
/// audio, and sends overlays and encoder commands back.
final class ScreenReceiver {
    static let shared = ScreenReceiver()

    /// (connected, width, height, error)
    var onState: ((Bool, Int, Int, String?) -> Void)?
    /// Annex-B packet from the extension's encoder.
    var onVideo: ((_ annexB: Data, _ ptsUs: Int64, _ isKey: Bool, _ isConfig: Bool) -> Void)?
    /// Other apps' audio (games, videos), already mono Float at 44.1 kHz.
    let appAudio = AudioRing(capacity: 44_100 * 2)

    private let lock = NSLock()
    private var client: FramedSocket?
    private var listenFD: Int32 = -1
    private var resampler = LinearResampler(targetRate: 44_100)

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return client?.isOpen ?? false
    }

    func startListening() {
        guard listenFD < 0 else { return }
        guard let path = obsSocketPath() else {
            onState?(false, 0, 0, "Screen capture needs the App Group \(obsAppGroup) (see README).")
            return
        }
        guard let fd = unixListen(path) else {
            onState?(false, 0, 0, "Could not open the screen capture socket.")
            return
        }
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "obs-screen-accept"
        t.start()
    }

    @discardableResult
    func send(_ type: LinkMessage, _ payload: Data = Data()) -> Bool {
        lock.lock()
        let c = client
        lock.unlock()
        return c?.send(type, payload) ?? false
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                return
            }
            let socket = FramedSocket(fd: cfd)
            lock.lock()
            let old = client
            client = socket
            lock.unlock()
            old?.close()
            let t = Thread { [weak self] in self?.readLoop(socket) }
            t.name = "obs-screen-read"
            t.start()
        }
    }

    private func readLoop(_ socket: FramedSocket) {
        while let message = socket.receive() {
            guard let type = message.0 else { continue }
            var r = ByteReader(message.1)
            switch type {
            case .hello:
                if let w = r.u32(), let h = r.u32() { onState?(true, Int(w), Int(h), nil) }
            case .videoPacket:
                guard let flags = r.u8(), let pts = r.i64() else { continue }
                onVideo?(r.rest(), pts, flags & 2 != 0, flags & 1 != 0)
            case .appAudio:
                guard let rate = r.u32(), let channels = r.u8(), let format = r.u8(), r.i64() != nil else { continue }
                let mono = AudioDecode.mono(r.rest(), channels: Int(channels), format: format)
                appAudio.write(resampler.process(mono, sourceRate: Double(rate)))
            default:
                break
            }
        }
        lock.lock()
        let wasCurrent = client === socket
        if wasCurrent { client = nil }
        lock.unlock()
        socket.close()
        if wasCurrent {
            appAudio.clear()
            onState?(false, 0, 0, nil)
        }
    }
}

/// Thread-safe mono Float ring buffer (drops the oldest audio on overflow).
final class AudioRing {
    private var buf: [Float]
    private var readPos = 0
    private var count = 0
    private let lock = NSLock()

    init(capacity: Int) { buf = [Float](repeating: 0, count: capacity) }

    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for s in samples {
            let writePos = (readPos + count) % buf.count
            buf[writePos] = s
            if count < buf.count {
                count += 1
            } else {
                readPos = (readPos + 1) % buf.count
            }
        }
    }

    /// Reads up to `n` samples into `out` (zero-filled), returns how many were real.
    func read(into out: inout [Float], _ n: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let take = min(n, count)
        for i in 0..<n { out[i] = 0 }
        for i in 0..<take {
            out[i] = buf[readPos]
            readPos = (readPos + 1) % buf.count
        }
        count -= take
        return take
    }

    func clear() {
        lock.lock()
        readPos = 0
        count = 0
        lock.unlock()
    }
}

enum AudioDecode {
    /// Interleaved s16le / s16be / f32 -> mono Float.
    static func mono(_ data: Data, channels: Int, format: UInt8) -> [Float] {
        let ch = max(channels, 1)
        let bytesPerSample = format == 2 ? 4 : 2
        let frames = data.count / (bytesPerSample * ch)
        var out = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<ch {
                    let off = (f * ch + c) * bytesPerSample
                    switch format {
                    case 2:
                        sum += Float(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self).littleEndian)
                    case 1:
                        sum += Float(Int16(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self).bigEndian)) / 32768
                    default:
                        sum += Float(Int16(bitPattern: raw.loadUnaligned(fromByteOffset: off, as: UInt16.self).littleEndian)) / 32768
                    }
                }
                out[f] = sum / Float(ch)
            }
        }
        return out
    }
}

/// Streaming linear-interpolation resampler (mono).
struct LinearResampler {
    let targetRate: Double
    private var pos: Double = 0 // position in the current input block; may be in [-1, 0)
    private var prev: Float = 0

    init(targetRate: Double) { self.targetRate = targetRate }

    mutating func process(_ input: [Float], sourceRate: Double) -> [Float] {
        let n = input.count
        guard n > 0, sourceRate > 0 else { return [] }
        if sourceRate == targetRate { return input }
        let step = sourceRate / targetRate
        var out: [Float] = []
        out.reserveCapacity(Int(Double(n) / step) + 2)
        while pos < Double(n - 1) {
            let i = Int(pos.rounded(.down))
            let frac = Float(pos - Double(i))
            let a = i < 0 ? prev : input[i]
            let b = input[i + 1]
            out.append(a + (b - a) * frac)
            pos += step
        }
        pos -= Double(n)
        prev = input[n - 1]
        return out
    }
}
