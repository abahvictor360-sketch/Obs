import AudioToolbox
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import VideoToolbox

/// Decodes what phones and encoders stream into OBSpad over RTMP (the
/// "Phone / Encoder (RTMP)" source): Dart runs the RTMP server and passes
/// the H.264 video and AAC audio here. Video is decoded by VideoToolbox onto
/// a Flutter texture; audio is decoded to PCM and mixed into the stream
/// through LiveAudio. Same channel contract as android/.../StreamInPlugin.kt.
final class StreamInPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    private let textures: FlutterTextureRegistry
    private var decoders: [String: StreamDecoder] = [:]

    init(channel: FlutterMethodChannel, textures: FlutterTextureRegistry) {
        self.channel = channel
        self.textures = textures
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "obs_tablet/stream_in", binaryMessenger: registrar.messenger())
        let instance = StreamInPlugin(channel: channel, textures: registrar.textures())
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let id = args["id"] as? String else {
            result(FlutterError(code: "args", message: "id missing", details: nil))
            return
        }
        func bytes(_ key: String) -> Data { (args[key] as? FlutterStandardTypedData)?.data ?? Data() }
        switch call.method {
        case "open":
            decoders[id]?.close()
            let d = StreamDecoder(id: id, registry: textures, onSize: { [weak self] w, h in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("videoSize", arguments: ["id": id, "width": w, "height": h])
                }
            }, onError: { [weak self] message in
                DispatchQueue.main.async {
                    self?.channel.invokeMethod("error", arguments: ["id": id, "message": message])
                }
            })
            decoders[id] = d
            result(["textureId": d.textureId])
        case "videoConfig":
            decoders[id]?.videoConfig(bytes("avcc"))
            result(nil)
        case "video":
            decoders[id]?.video(bytes("data"), key: (args["key"] as? Bool) ?? false)
            result(nil)
        case "audioConfig":
            decoders[id]?.audioConfig(bytes("asc"))
            result(nil)
        case "audio":
            decoders[id]?.audio(bytes("data"))
            result(nil)
        case "close":
            decoders.removeValue(forKey: id)?.close()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// One RTMP input's decoders, on their own queue.
final class StreamDecoder: NSObject, FlutterTexture {
    private let id: String
    private weak var registry: FlutterTextureRegistry?
    private(set) var textureId: Int64 = 0
    private let onSize: (Int, Int) -> Void
    private let onError: (String) -> Void
    private let queue = DispatchQueue(label: "org.obstablet.stream-in")

    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var closed = false

    // Video
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var avcc = Data()
    private var waitKey = true
    private var width = 0
    private var height = 0

    // Audio
    private var converter: AudioConverterRef?
    private var audioRate: Double = 44100
    private var audioChannels: UInt32 = 2

    init(id: String, registry: FlutterTextureRegistry, onSize: @escaping (Int, Int) -> Void,
         onError: @escaping (String) -> Void) {
        self.id = id
        self.registry = registry
        self.onSize = onSize
        self.onError = onError
        super.init()
        textureId = registry.register(self)
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let pb = latest else { return nil }
        return Unmanaged.passRetained(pb)
    }

    fileprivate func show(_ pb: CVPixelBuffer) {
        lock.lock()
        latest = pb
        let isClosed = closed
        lock.unlock()
        if isClosed { return }
        let id = textureId
        DispatchQueue.main.async { [weak self] in self?.registry?.textureFrameAvailable(id) }
    }

    // MARK: Video

    func videoConfig(_ config: Data) {
        queue.async {
            if config == self.avcc { return }
            self.avcc = config
            self.restartVideo()
        }
    }

    private func restartVideo() {
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        format = nil
        guard let parsed = StreamDecoder.parseAvcc([UInt8](avcc)) else {
            onError("The phone sent a video format OBSpad can't read. Use H.264 (AVC).")
            return
        }
        let (sps, pps, lengthSize) = parsed
        var fd: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: Int32(lengthSize),
                    formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let desc = fd else {
            onError("Video decoder: format error \(status)")
            return
        }
        format = desc
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        if Int(dims.width) != width || Int(dims.height) != height {
            width = Int(dims.width)
            height = Int(dims.height)
            onSize(width, height)
        }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { refCon, _, status, _, imageBuffer, _, _ in
                guard status == noErr, let refCon = refCon, let ib = imageBuffer else { return }
                Unmanaged<StreamDecoder>.fromOpaque(refCon).takeUnretainedValue().show(ib)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var s: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: attrs as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &s)
        if created != noErr {
            onError("Video decoder: could not start (\(created))")
            return
        }
        session = s
        waitKey = true
    }

    func video(_ data: Data, key: Bool) {
        queue.async {
            if self.closed { return }
            if self.waitKey && !key { return }
            guard let session = self.session, let fd = self.format, !data.isEmpty else { return }
            self.waitKey = false
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                dataLength: data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                let bb = block else { return }
            let copied: OSStatus = data.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0,
                                              dataLength: data.count)
            }
            guard copied == noErr else { return }
            var sample: CMSampleBuffer?
            var sizes = [data.count]
            guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                sampleSizeArray: &sizes, sampleBufferOut: &sample) == noErr, let sb = sample else { return }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb, flags: [], frameRefcon: nil,
                                                           infoFlagsOut: nil)
            if status == kVTInvalidSessionErr {
                self.restartVideo()
            } else if status != noErr {
                self.waitKey = true // bad data: wait for the next keyframe
            }
        }
    }

    // MARK: Audio

    func audioConfig(_ asc: Data) {
        queue.async {
            guard !self.closed, asc.count >= 2 else { return }
            if let c = self.converter {
                AudioConverterDispose(c)
                self.converter = nil
            }
            let (rate, ch) = StreamDecoder.parseAsc([UInt8](asc))
            self.audioRate = rate
            self.audioChannels = ch
            var inFmt = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: ch, mBitsPerChannel: 0, mReserved: 0)
            var outFmt = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch, mChannelsPerFrame: ch,
                mBitsPerChannel: 32, mReserved: 0)
            var conv: AudioConverterRef?
            let status = AudioConverterNew(&inFmt, &outFmt, &conv)
            if status != noErr {
                self.onError("Audio decoder: could not start (\(status))")
                return
            }
            self.converter = conv
        }
    }

    func audio(_ data: Data) {
        queue.async {
            guard !self.closed, let conv = self.converter, !data.isEmpty else { return }
            let ch = Int(self.audioChannels)
            let input = AACPacket(data: data, channels: self.audioChannels)
            defer { input.free() }
            var out = [Float](repeating: 0, count: 1024 * ch)
            var frames: UInt32 = 1024
            let status: OSStatus = out.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(raw.count),
                                          mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(conv, aacInputProc, Unmanaged.passUnretained(input).toOpaque(),
                                                       &frames, &abl, nil)
            }
            if status != noErr && status != aacNoMoreData {
                AudioConverterReset(conv)
                return
            }
            if frames > 0 {
                LiveAudio.shared.push(id: self.id, pcm: Array(out[0..<(Int(frames) * ch)]), channels: ch,
                                      rate: self.audioRate)
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        latest = nil
        lock.unlock()
        queue.async {
            if let s = self.session {
                VTDecompressionSessionInvalidate(s)
                self.session = nil
            }
            if let c = self.converter {
                AudioConverterDispose(c)
                self.converter = nil
            }
        }
        registry?.unregisterTexture(textureId)
    }

    // MARK: Parsing

    /// First SPS and PPS and the NAL length size from an avcC record.
    static func parseAvcc(_ c: [UInt8]) -> ([UInt8], [UInt8], Int)? {
        guard c.count >= 7, c[0] == 1 else { return nil }
        let lengthSize = Int(c[4] & 3) + 1
        var p = 5
        func sets(_ count: Int) -> [UInt8]? {
            var first: [UInt8]?
            for _ in 0..<count {
                guard p + 2 <= c.count else { return nil }
                let len = (Int(c[p]) << 8) | Int(c[p + 1])
                p += 2
                guard p + len <= c.count else { return nil }
                if first == nil { first = Array(c[p..<(p + len)]) }
                p += len
            }
            return first
        }
        let numSps = Int(c[p] & 0x1F)
        p += 1
        guard let sps = sets(numSps), p < c.count else { return nil }
        let numPps = Int(c[p])
        p += 1
        guard let pps = sets(numPps) else { return nil }
        return (sps, pps, lengthSize)
    }

    private static let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000,
                                          11025, 8000, 7350]

    /// Sample rate and channels from an AAC AudioSpecificConfig.
    static func parseAsc(_ asc: [UInt8]) -> (Double, UInt32) {
        let idx = Int((asc[0] & 0x07) << 1) | Int(asc[1] >> 7)
        let ch = UInt32((asc[1] >> 3) & 0x0F)
        return (idx < rates.count ? rates[idx] : 44100, (1...2).contains(ch) ? ch : 2)
    }
}

/// Returned by the input callback once its one packet has been handed over.
private let aacNoMoreData: OSStatus = -12345

/// One AAC packet handed to AudioConverterFillComplexBuffer.
private final class AACPacket {
    let buffer: UnsafeMutableRawPointer
    let size: Int
    let channels: UInt32
    let desc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    var consumed = false

    init(data: Data, channels: UInt32) {
        size = data.count
        self.channels = channels
        buffer = UnsafeMutableRawPointer.allocate(byteCount: max(size, 1), alignment: 1)
        data.withUnsafeBytes { raw in buffer.copyMemory(from: raw.baseAddress!, byteCount: size) }
    }

    func free() {
        buffer.deallocate()
        desc.deallocate()
    }
}

private let aacInputProc: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
    guard let user = user else { return aacNoMoreData }
    let packet = Unmanaged<AACPacket>.fromOpaque(user).takeUnretainedValue()
    if packet.consumed {
        ioPackets.pointee = 0
        return aacNoMoreData
    }
    packet.consumed = true
    ioPackets.pointee = 1
    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = packet.buffer
    ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.size)
    ioData.pointee.mBuffers.mNumberChannels = packet.channels
    packet.desc.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                       mDataByteSize: UInt32(packet.size))
    outDesc?.pointee = packet.desc
    return noErr
}
