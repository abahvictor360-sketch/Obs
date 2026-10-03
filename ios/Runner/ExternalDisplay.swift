import Flutter
import UIKit

/// Program on a screen connected through a dock, USB-C / HDMI adapter or
/// AirPlay (like OBS's fullscreen projector).
///
/// iPadOS gives the app an external display scene
/// (UIWindowSceneSessionRoleExternalDisplayNonInteractive in Info.plist)
/// when a screen is connected and Stage Manager isn't using it as an extended
/// desktop. The scene shows the frames Dart sends on
/// "obs_tablet/display_frames". In "mirror" mode the scene is closed and the
/// system mirrors the tablet.
final class ExternalDisplay {
    static let shared = ExternalDisplay()

    /// Called on the main thread whenever the screen or mode changes.
    var onChange: (() -> Void)?

    private(set) var mode = "program"
    private var scene: UIWindowScene?
    private var window: UIWindow?
    private var view: ProgramDisplayView?
    private var channel: FlutterBasicMessageChannel?

    private init() {
        let nc = NotificationCenter.default
        for name in [UIScreen.didConnectNotification, UIScreen.didDisconnectNotification, UIScreen.modeDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.onChange?() }
        }
    }

    func register(messenger: FlutterBinaryMessenger) {
        let ch = FlutterBasicMessageChannel(
            name: "obs_tablet/display_frames",
            binaryMessenger: messenger,
            codec: FlutterBinaryCodec.sharedInstance()
        )
        ch.setMessageHandler { [weak self] message, reply in
            if let data = message as? Data { self?.show(frame: data) }
            reply(nil)
        }
        channel = ch
    }

    // MARK: Scene lifecycle (ExternalDisplaySceneDelegate)

    func attach(_ s: UIWindowScene) {
        if mode == "mirror" {
            UIApplication.shared.requestSceneSessionDestruction(s.session, options: nil, errorHandler: nil)
            return
        }
        scene = s
        let w = UIWindow(windowScene: s)
        let v = ProgramDisplayView(frame: w.bounds)
        let vc = UIViewController()
        vc.view = v
        w.rootViewController = vc
        w.isHidden = false
        window = w
        view = v
        onChange?()
    }

    func detach(_ s: UIScene) {
        guard s === scene else { return }
        window?.isHidden = true
        window = nil
        view = nil
        scene = nil
        onChange?()
    }

    func setMode(_ m: String) {
        mode = m == "mirror" ? "mirror" : "program"
        if mode == "mirror", let s = scene {
            UIApplication.shared.requestSceneSessionDestruction(s.session, options: nil, errorHandler: nil)
            detach(s)
        }
        onChange?()
    }

    // MARK: State

    /// The connected screen, or nil. Without our scene (mirroring, or Stage
    /// Manager's extended display) it's found through UIScreen.screens.
    func state() -> [String: Any]? {
        let screen: UIScreen? = scene?.screen ?? UIScreen.screens.first { $0 != UIScreen.main }
        guard let screen = screen else { return nil }
        let size = screen.nativeBounds.size
        return [
            "name": "External display",
            "width": Int(max(size.width, size.height)),
            "height": Int(min(size.width, size.height)),
            "refreshRate": Double(screen.maximumFramesPerSecond),
            "presenting": scene != nil,
            // The system only offers the scene when a screen connects.
            "needsReconnect": scene == nil && mode == "program",
        ]
    }

    // MARK: Frames

    /// Message: width, height (uint32 little-endian) then RGBA pixels.
    private func show(frame data: Data) {
        guard let view = view, data.count >= 8 else { return }
        let w = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian)
        let h = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }.littleEndian)
        guard w > 0, h > 0, data.count >= 8 + w * h * 4 else { return }
        let pixels = data.subdata(in: 8 ..< 8 + w * h * 4)
        guard let image = Compositor.cgImage(rgba: pixels, width: w, height: h) else { return }
        view.show(image)
    }
}

/// Black, letterboxed full-screen image. Shows the app name until the first
/// frame arrives.
final class ProgramDisplayView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
        label.text = "ObsPad"
        label.textColor = UIColor(white: 1, alpha: 0.4)
        label.font = .boldSystemFont(ofSize: 48)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ image: CGImage) {
        label.isHidden = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }
}

/// Scene delegate for the external display role (see Info.plist).
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.attach(ws)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.detach(scene)
    }
}
