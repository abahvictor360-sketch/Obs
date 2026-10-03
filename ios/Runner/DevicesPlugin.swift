import AVFoundation
import Flutter
import Network

/// Hardware over USB-C: external cameras / capture cards (iPadOS 17+, UVC),
/// audio inputs (USB mics and interfaces), network type (USB Ethernet),
/// and docking stations / connected screens ([ExternalDisplay]).
/// Same channel contract as android/.../DevicesPlugin.kt.
final class DevicesPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private let textures: FlutterTextureRegistry
    private var camera: ExternalCamera?
    private let monitor = NWPathMonitor()
    private var path: NWPath?

    init(textures: FlutterTextureRegistry) {
        self.textures = textures
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = DevicesPlugin(textures: registrar.textures())
        let method = FlutterMethodChannel(name: "obs_tablet/devices", binaryMessenger: registrar.messenger())
        let events = FlutterEventChannel(name: "obs_tablet/device_events", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        events.setStreamHandler(instance)
        ExternalDisplay.shared.register(messenger: registrar.messenger())
        ExternalDisplay.shared.onChange = { [weak instance] in instance?.emitDock() }
        instance.startObserving()
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        emit(networkState().merging(["type": "network"]) { $1 })
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    private func emit(_ e: [String: Any]) {
        DispatchQueue.main.async { self.sink?(e) }
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "listUsbCameras":
            result(externalCameras().map { ["id": $0.uniqueID, "name": $0.localizedName] })
        case "openUsbCamera":
            openCamera(args["id"] as? String, result)
        case "closeUsbCamera":
            camera?.stop()
            camera = nil
            result(nil)
        case "listAudioInputs":
            result(audioInputs())
        case "setAudioInput":
            AudioRouting.preferredUID = args["id"] as? String
            AudioRouting.apply()
            result(nil)
        case "getDock":
            result(dockState())
        case "setDisplayMode":
            ExternalDisplay.shared.setMode(args["mode"] as? String ?? "program")
            result(dockState())
        case "getNetwork", "setPreferWired":
            // iPadOS already prefers a wired connection when one is plugged in.
            result(networkState())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: External cameras

    private func externalCameras() -> [AVCaptureDevice] {
        if #available(iOS 17.0, *) {
            return AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            ).devices
        }
        return []
    }

    private func openCamera(_ id: String?, _ result: @escaping FlutterResult) {
        guard #available(iOS 17.0, *) else {
            result(FlutterError(code: "usb", message: "USB cameras need iPadOS 17 or newer", details: nil))
            return
        }
        let devices = externalCameras()
        guard let device = devices.first(where: { $0.uniqueID == id }) ?? devices.first else {
            result(FlutterError(code: "usb", message: "No USB camera or capture card connected", details: nil))
            return
        }
        if let cam = camera, cam.device.uniqueID == device.uniqueID {
            result(cam.info)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                guard granted else {
                    result(FlutterError(code: "usb", message: "Camera permission denied", details: nil))
                    return
                }
                self.camera?.stop()
                do {
                    let cam = try ExternalCamera(device: device, registry: self.textures)
                    self.camera = cam
                    result(cam.info)
                    self.emit(cam.info.merging(["type": "usbVideo", "state": "opened"]) { $1 })
                } catch {
                    result(FlutterError(code: "usb", message: error.localizedDescription, details: nil))
                }
            }
        }
    }

    // MARK: Audio inputs

    private func audioInputs() -> [[String: Any]] {
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playAndRecord, mode: .videoRecording,
                                     options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        }
        return (session.availableInputs ?? []).map { port in
            let type: String
            switch port.portType {
            case .usbAudio: type = "usb"
            case .bluetoothHFP: type = "bluetooth"
            case .headsetMic: type = "headset"
            case .builtInMic: type = "builtin"
            default: type = "other"
            }
            return ["id": port.uid, "name": port.portName, "type": type]
        }
    }

    // MARK: Network

    private func networkState() -> [String: Any] {
        let transport: String
        if let p = path, p.status == .satisfied {
            if p.usesInterfaceType(.wiredEthernet) {
                transport = "ethernet"
            } else if p.usesInterfaceType(.wifi) {
                transport = "wifi"
            } else if p.usesInterfaceType(.cellular) {
                transport = "cellular"
            } else {
                transport = "other"
            }
        } else {
            transport = "none"
        }
        let wired = path?.availableInterfaces.contains { $0.type == .wiredEthernet } ?? false
        return ["transport": transport, "wiredAvailable": wired, "preferWired": false, "canPreferWired": false]
    }

    // MARK: Docking station

    /// iPadOS doesn't report a dock as such; it's recognised from what comes
    /// through it (screen, Ethernet, USB audio, capture cards, power).
    private func dockState() -> [String: Any] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let usbAudio = (session.availableInputs ?? []).contains { $0.portType == .usbAudio } ||
            route.outputs.contains { $0.portType == .usbAudio || $0.portType == .HDMI }
        let battery = UIDevice.current.batteryState
        var state: [String: Any] = [
            "ethernet": path?.availableInterfaces.contains { $0.type == .wiredEthernet } ?? false,
            "usbAudio": usbAudio,
            "usbVideo": !externalCameras().isEmpty,
            "usbDevices": 0,
            "charging": battery == .charging || battery == .full,
        ]
        if let display = ExternalDisplay.shared.state() {
            state["display"] = display
            state["displays"] = [display]
        }
        return state
    }

    func emitDock() {
        DispatchQueue.main.async {
            self.sink?(self.dockState().merging(["type": "dock"]) { $1 })
        }
    }

    private func startObserving() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.emitDock() }

        monitor.pathUpdateHandler = { [weak self] p in
            guard let self = self else { return }
            self.path = p
            self.emit(self.networkState().merging(["type": "network"]) { $1 })
            self.emitDock()
        }
        monitor.start(queue: DispatchQueue(label: "org.obstablet.network"))

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.emit(["type": "audioInputs", "inputs": self.audioInputs()])
            self.emitDock()
        }
        nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard let d = n.object as? AVCaptureDevice, d.hasMediaType(.video) else { return }
            self?.emit(["type": "usbVideo", "state": "attached", "id": d.uniqueID, "name": d.localizedName])
            self?.emitDock()
        }
        nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] n in
            guard let self = self, let d = n.object as? AVCaptureDevice, d.hasMediaType(.video) else { return }
            if self.camera?.device.uniqueID == d.uniqueID {
                self.camera?.stop()
                self.camera = nil
            }
            self.emit(["type": "usbVideo", "state": "detached", "id": d.uniqueID])
            self.emitDock()
        }
    }
}

/// Preferred microphone; applied whenever the audio session is (re)configured.
enum AudioRouting {
    static var preferredUID: String?

    static func apply() {
        let session = AVAudioSession.sharedInstance()
        let port = session.availableInputs?.first { $0.uid == preferredUID }
        try? session.setPreferredInput(port)
    }
}

/// An external (USB) camera feeding a Flutter texture.
final class ExternalCamera: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {
    let device: AVCaptureDevice
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "org.obstablet.usbcam")
    private weak var registry: FlutterTextureRegistry?
    private var textureId: Int64 = 0
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    init(device: AVCaptureDevice, registry: FlutterTextureRegistry) throws {
        self.device = device
        self.registry = registry
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "obs", code: 1, userInfo: [NSLocalizedDescriptionKey: "Camera is busy"])
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        textureId = registry.register(self)
        queue.async { self.session.startRunning() }
    }

    var info: [String: Any] {
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return ["textureId": textureId, "width": Int(dims.width), "height": Int(dims.height), "id": device.uniqueID]
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        lock.lock()
        defer { lock.unlock() }
        guard let pb = latest else { return nil }
        return Unmanaged.passRetained(pb)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = pb
        lock.unlock()
        let id = textureId
        DispatchQueue.main.async { [weak self] in self?.registry?.textureFrameAvailable(id) }
    }

    func stop() {
        queue.async { self.session.stopRunning() }
        registry?.unregisterTexture(textureId)
    }
}
