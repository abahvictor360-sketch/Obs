// Local socket link between the app and the ReplayKit broadcast extension.
// Shared by both targets.
//
// Wire format: [type: u8][length: u32 big-endian][payload].
//
// Extension -> app:
//   videoPacket  u8 flags (bit0 config, bit1 keyframe), i64 ptsUs, Annex-B bytes
//   appAudio     u32 sampleRate, u8 channels, u8 format (0 s16le, 1 s16be, 2 f32), i64 ptsUs, samples
//   hello        u32 width, u32 height (size of the captured screen)
// App -> extension:
//   startEncoder u32 width, height, fps, bitrate, keyframeIntervalSec
//   stopEncoder  (empty)
//   overlays     u32 w, u32 h, u8 flags (bit0 under, bit1 over, bit2 clearOver),
//                f32 x, y, width, height, rotation, u8 fit, [u32 len, under], [u32 len, over]
//   keyframe     (empty)
//   finish       (empty) - stop the broadcast

import CoreGraphics
import CoreMedia
import Darwin
import Foundation

let obsAppGroup = "group.org.obstablet.obsTablet"

func obsSocketPath() -> String? {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: obsAppGroup)?
        .appendingPathComponent("obs.sock").path
}

enum LinkMessage: UInt8 {
    case videoPacket = 1
    case appAudio = 2
    case hello = 3
    case startEncoder = 10
    case stopEncoder = 11
    case overlays = 12
    case keyframe = 13
    case finish = 14
}

/// Microseconds on the host clock (mach absolute time), shared by both
/// processes so audio from the app and video from the extension line up.
func hostNowUs() -> Int64 {
    CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000, method: .default).value
}

struct ByteWriter {
    var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }

    mutating func u32(_ v: UInt32) {
        var b = v.bigEndian
        withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
    }

    mutating func i64(_ v: Int64) {
        var b = v.bigEndian
        withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
    }

    mutating func f32(_ v: Float) { u32(v.bitPattern) }

    mutating func bytes(_ d: Data) { data.append(d) }

    mutating func sized(_ d: Data) {
        u32(UInt32(d.count))
        data.append(d)
    }
}

struct ByteReader {
    private let data: Data
    private var pos: Int

    init(_ d: Data) {
        data = d
        pos = d.startIndex
    }

    var remaining: Int { data.endIndex - pos }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { pos += 1 }
        return data[pos]
    }

    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[pos + i]) }
        pos += 4
        return v
    }

    mutating func i64() -> Int64? {
        guard remaining >= 8 else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[pos + i]) }
        pos += 8
        return Int64(bitPattern: v)
    }

    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, remaining >= n else { return nil }
        defer { pos += n }
        return data.subdata(in: pos..<(pos + n))
    }

    mutating func rest() -> Data { bytes(remaining) ?? Data() }

    mutating func sized() -> Data? {
        guard let n = u32() else { return nil }
        return bytes(Int(n))
    }
}

/// Blocking, message-framed stream socket. Writes are serialized; reads
/// happen on one dedicated thread.
final class FramedSocket {
    let fd: Int32
    private let writeLock = NSLock()
    private var open = true

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    var isOpen: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return open
    }

    @discardableResult
    func send(_ type: LinkMessage, _ payload: Data = Data()) -> Bool {
        var header = ByteWriter()
        header.u8(type.rawValue)
        header.u32(UInt32(payload.count))
        writeLock.lock()
        defer { writeLock.unlock() }
        guard open else { return false }
        return writeAll(header.data) && writeAll(payload)
    }

    private func writeAll(_ d: Data) -> Bool {
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                left -= n
                p = p.advanced(by: n)
            }
            return true
        }
    }

    /// Next message, or nil once the peer has gone away.
    func receive() -> (LinkMessage?, Data)? {
        guard let header = readExactly(5) else { return nil }
        var r = ByteReader(header)
        guard let typeRaw = r.u8(), let len = r.u32(), len <= 64 << 20 else { return nil }
        guard let body = readExactly(Int(len)) else { return nil }
        return (LinkMessage(rawValue: typeRaw), body)
    }

    private func readExactly(_ n: Int) -> Data? {
        if n == 0 { return Data() }
        var data = Data(count: n)
        let ok = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var got = 0
            while got < n {
                let r = Darwin.read(fd, base.advanced(by: got), n - got)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { return false }
                got += r
            }
            return true
        }
        return ok ? data : nil
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        if open {
            open = false
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

private func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    return addr
}

func unixConnect(_ path: String) -> Int32? {
    guard var addr = unixAddress(path) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if r != 0 {
        close(fd)
        return nil
    }
    return fd
}

func unixListen(_ path: String) -> Int32? {
    guard var addr = unixAddress(path) else { return nil }
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard r == 0, listen(fd, 2) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

/// Overlay layer update sent from the app to the extension.
struct OverlayUpdate {
    var width: Int
    var height: Int
    var under: Data?
    var over: Data?
    var clearOver: Bool
    var placement: ScreenPlacement

    func encode() -> Data {
        var w = ByteWriter()
        w.u32(UInt32(width))
        w.u32(UInt32(height))
        var flags: UInt8 = 0
        if under != nil { flags |= 1 }
        if over != nil { flags |= 2 }
        if clearOver { flags |= 4 }
        w.u8(flags)
        w.f32(Float(placement.x))
        w.f32(Float(placement.y))
        w.f32(Float(placement.width))
        w.f32(Float(placement.height))
        w.f32(Float(placement.rotation))
        w.u8(placement.fit.rawValue)
        if let u = under { w.sized(u) }
        if let o = over { w.sized(o) }
        return w.data
    }

    static func decode(_ d: Data) -> OverlayUpdate? {
        var r = ByteReader(d)
        guard let w = r.u32(), let h = r.u32(), let flags = r.u8(),
              let x = r.f32(), let y = r.f32(), let pw = r.f32(), let ph = r.f32(), let rot = r.f32(),
              let fitRaw = r.u8()
        else { return nil }
        let under = flags & 1 != 0 ? r.sized() : nil
        let over = flags & 2 != 0 ? r.sized() : nil
        return OverlayUpdate(
            width: Int(w),
            height: Int(h),
            under: under,
            over: over,
            clearOver: flags & 4 != 0,
            placement: ScreenPlacement(
                x: CGFloat(x), y: CGFloat(y), width: CGFloat(pw), height: CGFloat(ph),
                rotation: CGFloat(rot), fit: ScreenFit(rawValue: fitRaw) ?? .contain
            )
        )
    }
}
