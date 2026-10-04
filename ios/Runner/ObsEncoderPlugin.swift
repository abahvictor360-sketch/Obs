import AVFoundation
import Flutter
import ReplayKit
import UIKit

/// iPad implementation of the "obs_tablet/encoder" channels; same contract
/// as android/.../ObsEncoderPlugin.kt (see lib/output/encoder_backend.dart).
final class ObsEncoderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    private var video: AppVideoEncoder?
    private var audio: AppAudioEncoder?
    private var recorder: Mp4Writer?
    private var config: [String: Any] = [:]
    private var micGain: Float = 1
    private var appGain: Float = 1
    private var pcmTap = false
    private var meter: MicMeter?
    private var meterWanted = false

    /// True while the broadcast extension encodes the composited screen.
    private var extensionEncoding = false
    private var lastOverlays: OverlayUpdate?
    private var screenActive = false
    private var picker: RPSystemBroadcastPickerView?

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ObsEncoderPlugin()
        let method = FlutterMethodChannel(name: "obs_tablet/encoder", binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: "obs_tablet/encoder_events", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        events.setStreamHandler(instance)
        instance.setUpScreenReceiver()
        MicProcessing.shared.onNoiseSuppressionChange = { [weak instance] in
            guard let plugin = instance else { return }
            plugin.audio?.restartInput()
            if plugin.meter != nil {
                plugin.stopMeter()
                plugin.updateMeter()
            }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func emit(_ event: [String: Any]) {
        DispatchQueue.main.async { self.sink?(event) }
    }

    private func emitError(_ message: String) {
        emit(["type": "error", "message": message])
    }

    private func emitPacket(video: Bool, config: Bool, key: Bool, ptsUs: Int64, data: Data) {
        emit([
            "type": "packet",
            "kind": video ? "video" : "audio",
            "config": config,
            "key": key,
            "pts": ptsUs,
            "data": FlutterStandardTypedData(bytes: data),
        ])
    }

    // MARK: Method calls

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "isSupported", "isScreenCaptureSupported":
            result(true)
        case "start":
            start(args, result)
        case "stop":
            stop()
            updateMeter()
            result(nil)
        case "frame":
            guard let v = video, let data = (args["data"] as? FlutterStandardTypedData)?.data else {
                result(nil)
                return
            }
            if extensionEncoding {
                // Back to plain frames: the app encodes again.
                extensionEncoding = false
                ScreenReceiver.shared.send(.stopEncoder)
                v.setSuspended(false)
            }
            v.drawFrame(data, width: args["width"] as? Int ?? 0, height: args["height"] as? Int ?? 0) {
                DispatchQueue.main.async { result(nil) }
            }
        case "overlays":
            overlays(args, result)
        case "requestKeyframe":
            if extensionEncoding {
                ScreenReceiver.shared.send(.keyframe)
            } else {
                video?.requestKeyframe()
            }
            result(nil)
        case "setMicGain":
            micGain = Float(args["gain"] as? Double ?? 1)
            audio?.gain = micGain
            meter?.gain = micGain
            result(nil)
        case "setMicProcessing":
            MicProcessing.shared.configure(args)
            result(nil)
        case "setOutputMetering":
            // iOS doesn't let apps measure what the system plays.
            result(nil)
        case "setMetering":
            meterWanted = args["enabled"] as? Bool ?? false
            updateMeter()
            result(nil)
        case "setPcmTap":
            pcmTap = args["enabled"] as? Bool ?? false
            result(nil)
        case "setScreenAudioGain":
            appGain = Float(args["gain"] as? Double ?? 1)
            audio?.appGain = appGain
            result(nil)
        case "startRecording":
            guard video != nil else {
                result(FlutterError(code: "encoder", message: "Encoder is not running", details: nil))
                return
            }
            let r = Mp4Writer(audioBitrate: (config["audioBitrate"] as? Int) ?? 160_000)
            recorder = r
            requestKeyframe()
            result(r.displayName)
        case "stopRecording":
            guard let r = recorder else {
                result(nil)
                return
            }
            recorder = nil
            r.finish { path in DispatchQueue.main.async { result(path) } }
        case "startScreenCapture":
            showBroadcastPicker()
            result(nil)
        case "stopScreenCapture":
            ScreenReceiver.shared.send(.finish)
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func requestKeyframe() {
        if extensionEncoding {
            ScreenReceiver.shared.send(.keyframe)
        } else {
            video?.requestKeyframe()
        }
    }

    // MARK: Encoders

    private func start(_ args: [String: Any], _ result: @escaping FlutterResult) {
        stop()
        stopMeter() // the encoder takes over the microphone and the levels
        config = args
        let width = args["width"] as? Int ?? 1280
        let height = args["height"] as? Int ?? 720
        let fps = args["fps"] as? Int ?? 30
        let bitrate = args["videoBitrate"] as? Int ?? 2_500_000
        let keyInt = args["keyframeInterval"] as? Int ?? 2

        video = AppVideoEncoder(
            width: width, height: height, fps: fps, bitrate: bitrate, keyframeIntervalSec: keyInt,
            onOutput: { [weak self] v in self?.onVideo(v.annexB, ptsUs: v.ptsUs, isKey: v.isKeyframe, config: v.config) },
            onError: { [weak self] m in self?.emitError(m) }
        )

        // The audio session must allow mixing so games keep their sound, and
        // must stay active so iOS keeps the app running in the background.
        let session = activateAudioSession()
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self, self.video != nil else { return }
                if granted {
                    self.startAudio(bitrate: args["audioBitrate"] as? Int ?? 160_000)
                } else {
                    self.emitError("Microphone permission denied: streaming without audio")
                }
            }
        }
        if screenActive, let o = lastOverlays {
            switchToExtension(o)
        }
        result(nil)
    }

    private func startAudio(bitrate: Int) {
        do {
            let a = try AppAudioEncoder(bitrate: bitrate)
            a.gain = micGain
            a.appGain = appGain
            a.onPacket = { [weak self] data, pts in
                self?.emitPacket(video: false, config: false, key: false, ptsUs: pts, data: data)
            }
            a.onPCM = { [weak self] pcm, pts in
                guard let self = self else { return }
                self.recorder?.appendAudio(pcm, ptsUs: pts)
                if self.pcmTap, let ch = pcm.floatChannelData {
                    let data = Data(bytes: ch[0], count: Int(pcm.frameLength) * MemoryLayout<Float>.size)
                    self.emit([
                        "type": "pcm",
                        "data": FlutterStandardTypedData(bytes: data),
                        "sampleRate": Int(AppAudioEncoder.sampleRate),
                        "channels": 1,
                    ])
                }
            }
            a.onLevel = { [weak self] rms, peak in
                self?.emit(["type": "level", "rms": Double(rms), "peak": Double(peak)])
            }
            emitPacket(video: false, config: true, key: false, ptsUs: 0, data: AppAudioEncoder.asc)
            try a.start()
            audio = a
        } catch {
            emitError("Microphone unavailable: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func activateAudioSession() -> AVAudioSession {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .videoRecording,
                                    options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            emitError("Audio session error: \(error.localizedDescription)")
        }
        return session
    }

    // MARK: Mixer meter while idle

    /// Runs the MicMeter while it's wanted and no encoder uses the microphone.
    private func updateMeter() {
        guard meterWanted, video == nil, audio == nil else {
            stopMeter()
            return
        }
        guard meter == nil else { return }
        let session = activateAudioSession()
        session.requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self, granted, self.meterWanted, self.meter == nil,
                      self.video == nil, self.audio == nil else { return }
                let m = MicMeter { [weak self] rms, peak in
                    self?.emit(["type": "level", "rms": Double(rms), "peak": Double(peak)])
                }
                m.gain = self.micGain
                do {
                    try m.start()
                    self.meter = m
                } catch {
                    // No microphone right now; the next setMetering tries again.
                }
            }
        }
    }

    private func stopMeter() {
        meter?.stop()
        meter = nil
    }

    private func stop() {
        if let r = recorder {
            recorder = nil
            r.finish { _ in }
        }
        audio?.stop()
        audio = nil
        video?.stop()
        video = nil
        if extensionEncoding {
            extensionEncoding = false
            ScreenReceiver.shared.send(.stopEncoder)
        }
        lastOverlays = nil
    }

    /// Video packets from either the app encoder or the extension.
    private func onVideo(_ annexB: Data, ptsUs: Int64, isKey: Bool, config: Data?) {
        if let c = config {
            emitPacket(video: true, config: true, key: false, ptsUs: ptsUs, data: c)
            recorder?.setVideoConfig(c)
        }
        guard !annexB.isEmpty else { return }
        emitPacket(video: true, config: false, key: isKey, ptsUs: ptsUs, data: annexB)
        recorder?.appendVideo(annexB, ptsUs: ptsUs, isKey: isKey)
    }

    // MARK: Screen capture

    private func overlays(_ args: [String: Any], _ result: @escaping FlutterResult) {
        guard let v = video else {
            result(nil)
            return
        }
        let update = OverlayUpdate(
            width: args["width"] as? Int ?? 0,
            height: args["height"] as? Int ?? 0,
            under: (args["under"] as? FlutterStandardTypedData)?.data,
            over: (args["over"] as? FlutterStandardTypedData)?.data,
            clearOver: args["clearOver"] as? Bool ?? false,
            placement: ScreenPlacement(map: args["placement"] as? [String: Any])
        )
        // Remember full layers so a (re)connecting extension gets both.
        var merged = update
        if let last = lastOverlays {
            if merged.under == nil { merged.under = last.under }
            if merged.over == nil && !merged.clearOver { merged.over = last.over }
        }
        lastOverlays = merged

        if screenActive {
            if !extensionEncoding {
                switchToExtension(merged)
            } else {
                ScreenReceiver.shared.send(.overlays, update.encode())
            }
            result(nil)
        } else {
            v.setOverlays(update) { DispatchQueue.main.async { result(nil) } }
        }
    }

    private func switchToExtension(_ overlays: OverlayUpdate) {
        guard let v = video else { return }
        var w = ByteWriter()
        w.u32(UInt32(v.width))
        w.u32(UInt32(v.height))
        w.u32(UInt32(config["fps"] as? Int ?? 30))
        w.u32(UInt32(config["videoBitrate"] as? Int ?? 2_500_000))
        w.u32(UInt32(config["keyframeInterval"] as? Int ?? 2))
        guard ScreenReceiver.shared.send(.startEncoder, w.data) else { return }
        ScreenReceiver.shared.send(.overlays, overlays.encode())
        extensionEncoding = true
        v.setSuspended(true)
    }

    private func setUpScreenReceiver() {
        let receiver = ScreenReceiver.shared
        receiver.onState = { [weak self] active, w, h, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.screenActive = active
                if active, self.video != nil, !self.extensionEncoding, let o = self.lastOverlays {
                    self.switchToExtension(o)
                } else if !active, self.extensionEncoding {
                    // Broadcast ended: the app composites again (black hole).
                    self.extensionEncoding = false
                    self.video?.setSuspended(false)
                }
                var e: [String: Any] = ["type": "screen", "state": active ? "active" : "stopped", "width": w, "height": h]
                if let error = error { e["error"] = error }
                self.emit(e)
            }
        }
        receiver.onVideo = { [weak self] annexB, pts, isKey, isConfig in
            DispatchQueue.main.async {
                guard let self = self, self.extensionEncoding else { return }
                if isConfig {
                    self.onVideo(Data(), ptsUs: pts, isKey: false, config: annexB)
                } else {
                    self.onVideo(annexB, ptsUs: pts, isKey: isKey, config: nil)
                }
            }
        }
        receiver.startListening()
    }

    private func showBroadcastPicker() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        let p = RPSystemBroadcastPickerView(frame: CGRect(x: -100, y: -100, width: 44, height: 44))
        p.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + ".BroadcastExtension"
        p.showsMicrophoneButton = false
        window.addSubview(p)
        picker = p
        // The picker only opens from its own button; press it for the user.
        for case let button as UIButton in p.subviews {
            button.sendActions(for: .touchUpInside)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.picker?.removeFromSuperview()
            self?.picker = nil
        }
    }
}
