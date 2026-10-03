// VideoToolbox H.264 encoder producing Annex-B access units, the same packet
// format the Android encoder sends to Dart. Shared by the app and the
// broadcast extension.

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct EncodedVideo {
    /// Annex-B access unit (no SPS/PPS).
    let annexB: Data
    let ptsUs: Int64
    let isKeyframe: Bool
    /// Annex-B SPS + PPS, set when the parameter sets changed.
    let config: Data?
}

private let startCode = Data([0, 0, 0, 1])

final class H264Encoder {
    let width: Int32
    let height: Int32
    private let fps: Int32
    private let bitrate: Int32
    private let keyframeIntervalSec: Int32

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true
    private var lastConfig: Data?

    var onOutput: ((EncodedVideo) -> Void)?
    var onError: ((String) -> Void)?

    init(width: Int, height: Int, fps: Int, bitrate: Int, keyframeIntervalSec: Int) {
        self.width = Int32(width)
        self.height = Int32(height)
        self.fps = Int32(max(fps, 1))
        self.bitrate = Int32(bitrate)
        self.keyframeIntervalSec = Int32(max(keyframeIntervalSec, 1))
        _ = createSession()
    }

    deinit { invalidate() }

    private func createSession() -> Bool {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &s
        )
        guard status == noErr, let session = s else {
            onError?("Could not create the video encoder (\(status))")
            return false
        }
        func set(_ key: CFString, _ value: CFTypeRef) {
            VTSessionSetProperty(session, key: key, value: value)
        }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse) // no B-frames
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
        // Cap bursts at 1.5x the target per second, like CBR-ish streaming.
        let bytesPerSecond = Double(bitrate) / 8 * 1.5
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * keyframeIntervalSec))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keyframeIntervalSec))
        VTCompressionSessionPrepareToEncodeFrames(session)
        lock.lock()
        self.session = session
        forceKeyframe = true
        lock.unlock()
        return true
    }

    func invalidate() {
        lock.lock()
        let s = session
        session = nil
        lock.unlock()
        if let s = s {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    /// A buffer from the encoder's own pool (BGRA, output size).
    func makePixelBuffer() -> CVPixelBuffer? {
        lock.lock()
        let s = session
        lock.unlock()
        guard let session = s, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsUs: Int64) {
        lock.lock()
        let s = session
        let key = forceKeyframe
        forceKeyframe = false
        lock.unlock()
        guard let session = s else {
            _ = createSession()
            return
        }
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            duration: .invalid,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            self?.handle(status, sampleBuffer)
        }
        if status == kVTInvalidSessionErr {
            // iOS tears encoder sessions down (e.g. after backgrounding); rebuild.
            invalidate()
            _ = createSession()
        } else if status != noErr {
            onError?("Video encode error \(status)")
        }
    }

    private func handle(_ status: OSStatus, _ sb: CMSampleBuffer?) {
        guard status == noErr, let sb = sb, CMSampleBufferDataIsReady(sb) else { return }

        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = atts.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var config: Data?
        var nalLength = 4
        if let fmt = CMSampleBufferGetFormatDescription(sb), let ps = H264Encoder.parameterSets(fmt) {
            nalLength = ps.2
            let c = startCode + ps.0 + startCode + ps.1
            if c != lastConfig {
                lastConfig = c
                config = c
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copied = avcc.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        let pts = CMTimeConvertScale(CMSampleBufferGetPresentationTimeStamp(sb), timescale: 1_000_000, method: .default)
        onOutput?(EncodedVideo(
            annexB: H264Encoder.avccToAnnexB(avcc, nalLength: nalLength),
            ptsUs: pts.value,
            isKeyframe: isKey,
            config: config
        ))
    }

    static func parameterSets(_ fmt: CMFormatDescription) -> (Data, Data, Int)? {
        var count = 0
        var nalLen: Int32 = 4
        var spsPtr: UnsafePointer<UInt8>?
        var spsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: &spsPtr, parameterSetSizeOut: &spsSize,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen
        ) == noErr, let sp = spsPtr, count >= 2 else { return nil }
        var ppsPtr: UnsafePointer<UInt8>?
        var ppsSize = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 1, parameterSetPointerOut: &ppsPtr, parameterSetSizeOut: &ppsSize,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
        ) == noErr, let pp = ppsPtr else { return nil }
        return (Data(bytes: sp, count: spsSize), Data(bytes: pp, count: ppsSize), Int(nalLen))
    }

    /// Length-prefixed NAL units -> start-code delimited.
    static func avccToAnnexB(_ avcc: Data, nalLength: Int) -> Data {
        var out = Data(capacity: avcc.count + 16)
        let bytes = [UInt8](avcc)
        var i = 0
        while i + nalLength <= bytes.count {
            var len = 0
            for k in 0..<nalLength { len = (len << 8) | Int(bytes[i + k]) }
            i += nalLength
            guard len > 0, i + len <= bytes.count else { break }
            out.append(startCode)
            out.append(contentsOf: bytes[i..<(i + len)])
            i += len
        }
        return out
    }

    /// Start-code delimited -> NAL units (without start codes).
    static func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var nals: [Data] = []
        var start = -1
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    if end > start && b[end - 1] == 0 { end -= 1 }
                    if end > start { nals.append(Data(b[start..<end])) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0 && start < b.count { nals.append(Data(b[start..<b.count])) }
        return nals
    }
}
