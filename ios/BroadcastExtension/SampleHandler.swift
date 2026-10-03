// ReplayKit broadcast upload extension ("OBS Tablet Screen").
//
// iOS only lets a broadcast extension see the whole screen, and only lets
// processes in the foreground (or extensions) use the hardware video encoder.
// So while the screen is being captured, this extension composites the
// layers the app sends (sources below/above the screen) with the live screen,
// encodes H.264 and streams the packets to the app over a local socket. The
// app keeps running in the background (audio mode) and does the microphone,
// RTMP streaming and recording.

import CoreImage
import CoreMedia
import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {
    private var link: FramedSocket?
    private let queue = DispatchQueue(label: "org.obstablet.screen.video")

    // Accessed on `queue` only.
    private var encoder: H264Encoder?
    private var compositor: Compositor?
    private var under: CIImage?
    private var over: CIImage?
    private var placement: ScreenPlacement?
    private var latestScreen: CIImage?
    private var timer: DispatchSourceTimer?

    private var lastHello = CGSize.zero

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let path = obsSocketPath() else {
            fail("The App Group for OBS Tablet is not configured.")
            return
        }
        guard let fd = unixConnect(path) else {
            fail("Open OBS Tablet first, then start the broadcast.")
            return
        }
        let socket = FramedSocket(fd: fd)
        link = socket
        Thread { [weak self] in self?.readLoop(socket) }.start()
    }

    override func broadcastFinished() {
        queue.sync { stopEncoding() }
        link?.close()
        link = nil
    }

    private func fail(_ message: String) {
        finishBroadcastWithError(NSError(
            domain: "org.obstablet.screen",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }

    // MARK: Commands from the app

    private func readLoop(_ socket: FramedSocket) {
        while let message = socket.receive() {
            guard let type = message.0 else { continue }
            let body = message.1
            switch type {
            case .startEncoder:
                var r = ByteReader(body)
                guard let w = r.u32(), let h = r.u32(), let fps = r.u32(), let bitrate = r.u32(), let keyInt = r.u32()
                else { continue }
                queue.async { self.startEncoding(Int(w), Int(h), Int(fps), Int(bitrate), Int(keyInt)) }
            case .stopEncoder:
                queue.async { self.stopEncoding() }
            case .overlays:
                guard let update = OverlayUpdate.decode(body) else { continue }
                let underImg = update.under.flatMap { Compositor.ciImage(rgba: $0, width: update.width, height: update.height) }
                let overImg = update.over.flatMap { Compositor.ciImage(rgba: $0, width: update.width, height: update.height) }
                queue.async {
                    if let u = underImg { self.under = u }
                    if let o = overImg {
                        self.over = o
                    } else if update.clearOver {
                        self.over = nil
                    }
                    self.placement = update.placement
                }
            case .keyframe:
                queue.async { self.encoder?.requestKeyframe() }
            case .finish:
                socket.close()
                fail("Screen capture was stopped from OBS Tablet.")
                return
            default:
                break
            }
        }
        // The app went away (closed or crashed): nothing left to stream to.
        if link === socket {
            queue.async { self.stopEncoding() }
            fail("OBS Tablet was closed.")
        }
    }

    // MARK: Encoding (on `queue`)

    private func startEncoding(_ w: Int, _ h: Int, _ fps: Int, _ bitrate: Int, _ keyInt: Int) {
        stopEncoding()
        let enc = H264Encoder(width: w, height: h, fps: fps, bitrate: bitrate, keyframeIntervalSec: keyInt)
        enc.onOutput = { [weak self] v in self?.sendVideo(v) }
        encoder = enc
        compositor = Compositor(width: w, height: h)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / max(fps, 1)))
        t.setEventHandler { [weak self] in self?.renderFrame() }
        t.resume()
        timer = t
    }

    private func stopEncoding() {
        timer?.cancel()
        timer = nil
        encoder?.invalidate()
        encoder = nil
        compositor = nil
    }

    private func renderFrame() {
        guard let enc = encoder, let comp = compositor, let pb = enc.makePixelBuffer() else { return }
        comp.render(to: pb, under: under, screen: latestScreen, placement: placement, over: over)
        enc.encode(pb, ptsUs: hostNowUs())
    }

    private func sendVideo(_ v: EncodedVideo) {
        guard let link = link else { return }
        if let config = v.config {
            var w = ByteWriter()
            w.u8(1)
            w.i64(v.ptsUs)
            w.bytes(config)
            link.send(.videoPacket, w.data)
        }
        var w = ByteWriter()
        w.u8(v.isKeyframe ? 2 : 0)
        w.i64(v.ptsUs)
        w.bytes(v.annexB)
        link.send(.videoPacket, w.data)
    }

    // MARK: Samples from ReplayKit

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            var orientation = CGImagePropertyOrientation.up
            if let o = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil)
                as? NSNumber, let parsed = CGImagePropertyOrientation(rawValue: o.uint32Value) {
                orientation = parsed
            }
            let image = CIImage(cvPixelBuffer: pb).oriented(orientation)
            let size = image.extent.size
            if size != lastHello {
                lastHello = size
                var w = ByteWriter()
                w.u32(UInt32(size.width))
                w.u32(UInt32(size.height))
                link?.send(.hello, w.data)
            }
            queue.async { self.latestScreen = image }
        case .audioApp:
            sendAppAudio(sampleBuffer)
        case .audioMic:
            break // the app records the microphone itself
        @unknown default:
            break
        }
    }

    private func sendAppAudio(_ sb: CMSampleBuffer) {
        guard let link = link,
              let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sb)
        else { return }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bigEndian = asbd.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return }
        var channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(sb)
        var length = CMBlockBufferGetDataLength(block)
        if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 && channels > 1 {
            // Planar: keep just the first channel.
            channels = 1
            length = min(length, frames * bits / 8)
        }
        var samples = Data(count: length)
        let ok = samples.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!) == kCMBlockBufferNoErr
        }
        guard ok else { return }
        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), timescale: 1_000_000, method: .default)
        var w = ByteWriter()
        w.u32(UInt32(asbd.mSampleRate))
        w.u8(UInt8(channels))
        w.u8(isFloat ? 2 : (bigEndian ? 1 : 0))
        w.i64(pts.value)
        w.bytes(samples)
        link.send(.appAudio, w.data)
    }
}
