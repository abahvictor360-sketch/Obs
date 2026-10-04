import AVFoundation
import Photos

/// MP4 recording with AVAssetWriter. Video is passed through (the H.264
/// packets already sent to the stream); audio is the mixed PCM, encoded to
/// AAC by the writer. On stop the file is saved to the Photos library.
final class Mp4Writer {
    private let url: URL
    private let name: String
    private let audioBitrate: Int
    private let queue = DispatchQueue(label: "org.obstablet.mp4")

    // On `queue`:
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var startUs: Int64 = -1
    private var finished = false

    init(audioBitrate: Int) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        name = "OBS \(f.string(from: Date())).mp4"
        // Documents/Recordings (visible in the Files app): if Photos access is
        // denied the file stays there instead of a purged temp folder.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
        self.audioBitrate = audioBitrate
        try? FileManager.default.removeItem(at: url)
    }

    var displayName: String { name }

    /// Annex-B SPS+PPS.
    func setVideoConfig(_ annexB: Data) {
        let nals = H264Encoder.splitAnnexB(annexB)
        guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return }
        queue.async {
            var fmt: CMFormatDescription?
            let status = sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> OSStatus in
                pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> OSStatus in
                    let pointers: [UnsafePointer<UInt8>] = [
                        s.bindMemory(to: UInt8.self).baseAddress!,
                        p.bindMemory(to: UInt8.self).baseAddress!,
                    ]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt
                    )
                }
            }
            // Parameter sets can't change mid-file; keep the first ones.
            if status == noErr, self.videoFormat == nil { self.videoFormat = fmt }
        }
    }

    func appendVideo(_ annexB: Data, ptsUs: Int64, isKey: Bool) {
        queue.async {
            guard !self.finished else { return }
            if self.writer == nil {
                // Start the file on a keyframe once the format is known.
                guard isKey, let fmt = self.videoFormat, self.startWriter(fmt, startUs: ptsUs) else { return }
            }
            guard let input = self.videoInput, input.isReadyForMoreMediaData,
                  let sb = Mp4Writer.videoSample(annexB, ptsUs: ptsUs, isKey: isKey, format: self.videoFormat!)
            else { return }
            input.append(sb)
        }
    }

    func appendAudio(_ pcm: AVAudioPCMBuffer, ptsUs: Int64) {
        queue.async {
            guard !self.finished, self.startUs >= 0, ptsUs >= self.startUs,
                  let input = self.audioInput, input.isReadyForMoreMediaData,
                  let sb = Mp4Writer.audioSample(pcm, ptsUs: ptsUs) else { return }
            input.append(sb)
        }
    }

    /// Finishes the file, saves it to Photos and returns where it went.
    func finish(_ completion: @escaping (String?) -> Void) {
        queue.async {
            self.finished = true
            guard let w = self.writer, w.status == .writing else {
                self.writer?.cancelWriting()
                completion(nil)
                return
            }
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            w.finishWriting {
                guard w.status == .completed else {
                    completion(nil)
                    return
                }
                self.saveToPhotos(completion)
            }
        }
    }

    private func startWriter(_ fmt: CMFormatDescription, startUs: Int64) -> Bool {
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            v.expectsMediaDataInRealTime = true
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: AppAudioEncoder.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: audioBitrate,
            ])
            a.expectsMediaDataInRealTime = true
            guard w.canAdd(v), w.canAdd(a) else { return false }
            w.add(v)
            w.add(a)
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: CMTime(value: startUs, timescale: 1_000_000))
            writer = w
            videoInput = v
            audioInput = a
            self.startUs = startUs
            return true
        } catch {
            return false
        }
    }

    private func saveToPhotos(_ completion: @escaping (String?) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(self.url.path)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: self.url, options: nil)
            }) { ok, _ in
                if ok {
                    try? FileManager.default.removeItem(at: self.url)
                    completion("Photos/\(self.name)")
                } else {
                    completion(self.url.path)
                }
            }
        }
    }

    private static func videoSample(_ annexB: Data, ptsUs: Int64, isKey: Bool, format: CMFormatDescription) -> CMSampleBuffer? {
        // Annex-B -> AVCC, dropping parameter sets / delimiters.
        var avcc = Data()
        for nal in H264Encoder.splitAnnexB(annexB) {
            let type = (nal.first ?? 0) & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard !avcc.isEmpty else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let bb = block else { return nil }
        let copied = avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0,
                                          dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = avcc.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: bb, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb
        ) == noErr, let sample = sb else { return nil }

        if !isKey, let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample
    }

    private static func audioSample(_ pcm: AVAudioPCMBuffer, ptsUs: Int64) -> CMSampleBuffer? {
        var fmt: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt
        ) == noErr, let format = fmt else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(pcm.format.sampleRate)),
            presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb
        ) == noErr, let sample = sb else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            bufferList: pcm.audioBufferList
        ) == noErr else { return nil }
        return sample
    }
}
