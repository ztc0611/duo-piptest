import AVFoundation
import AVKit
import UIKit

@main
struct PiPProbeMain {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = PlayerViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

private enum AspectRatio: Int, CaseIterable {
    case wide, standard, square, portrait, cinematic

    static let displayOrder: [AspectRatio] = [.cinematic, .wide, .standard, .square, .portrait]

    var title: String {
        switch self {
        case .wide: "16:9"
        case .standard: "4:3"
        case .square: "1:1"
        case .portrait: "9:16"
        case .cinematic: "21:9"
        }
    }

    var basename: String {
        switch self {
        case .wide: "gradient-16x9"
        case .standard: "gradient-4x3"
        case .square: "gradient-1x1"
        case .portrait: "gradient-9x16"
        case .cinematic: "gradient-21x9"
        }
    }
}

final class PlayerViewController: UIViewController, AVPictureInPictureControllerDelegate {
    private let aspectPreferenceKey = "selectedAspectRatio"
    private let player = AVQueuePlayer()
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var pipController: AVPictureInPictureController?
    private var selectedAspect: AspectRatio = .wide
    private var itemReady = false
    private var videoError: String?
    private var pipError: String?
    private var lastRecordedSize: String?

    private var possibleObservation: NSKeyValueObservation?
    private var activeObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var presentationSizeObservation: NSKeyValueObservation?
    private var looperStatusObservation: NSKeyValueObservation?

    private let panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    private let titleLabel = UILabel()
    private let ratioPicker = UISegmentedControl(items: AspectRatio.displayOrder.map(\.title))
    private let startButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        selectedAspect = AspectRatio(rawValue: UserDefaults.standard.integer(forKey: aspectPreferenceKey)) ?? .wide
        configureControls()

        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        view.layer.insertSublayer(playerLayer, at: 0)
        observePlayer()

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            record("audio session active")
        } catch {
            record("audio session error: \(error.localizedDescription)")
        }

        let supported = AVPictureInPictureController.isPictureInPictureSupported()
        pipController = AVPictureInPictureController(playerLayer: playerLayer)
        pipController?.delegate = self
        observePictureInPicture()
        record("supported=\(supported) controllerInitialized=\(pipController != nil)")
        loadVideo(for: selectedAspect)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        playerLayer.frame = view.bounds
    }

    deinit {
        possibleObservation = nil
        activeObservation = nil
        playerStatusObservation = nil
        currentItemObservation = nil
        itemStatusObservation = nil
        presentationSizeObservation = nil
        looperStatusObservation = nil
        pipController?.delegate = nil
        looper?.disableLooping()
        player.pause()
        player.removeAllItems()
    }

    private func configureControls() {
        panel.overrideUserInterfaceStyle = .dark
        panel.layer.cornerRadius = 18
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        titleLabel.text = "PiP Test"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.accessibilityTraits.insert(.header)

        ratioPicker.selectedSegmentIndex = AspectRatio.displayOrder.firstIndex(of: selectedAspect) ?? 0
        ratioPicker.accessibilityIdentifier = "aspectRatioPicker"
        ratioPicker.accessibilityLabel = "Video aspect ratio"
        ratioPicker.accessibilityValue = selectedAspect.title
        ratioPicker.addTarget(self, action: #selector(aspectChanged), for: .valueChanged)

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "Start PiP"
        startButton.configuration = buttonConfiguration
        startButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        startButton.titleLabel?.adjustsFontForContentSizeCategory = true
        startButton.accessibilityIdentifier = "startPiPButton"
        startButton.accessibilityLabel = "Start Picture in Picture"
        startButton.isEnabled = false
        startButton.addTarget(self, action: #selector(togglePiP), for: .touchUpInside)
        startButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .white
        statusLabel.numberOfLines = 0
        statusLabel.text = "Preparing video…"

        let stack = UIStackView(arrangedSubviews: [titleLabel, ratioPicker, startButton, statusLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView.addSubview(stack)

        let fillWidth = panel.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        fillWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            panel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            fillWidth,
            stack.leadingAnchor.constraint(equalTo: panel.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: panel.contentView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: panel.contentView.bottomAnchor, constant: -16)
        ])
        updateControls()
    }

    private func observePictureInPicture() {
        guard let pipController else { return }
        possibleObservation = pipController.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateControls() }
        }
        activeObservation = pipController.observe(\.isPictureInPictureActive, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateControls() }
        }
    }

    private func observePlayer() {
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, player.status == .failed else { return }
                self.failVideo(player.error?.localizedDescription ?? "Player failed to load the video.")
            }
        }
        currentItemObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { self?.observeCurrentItem(player.currentItem) }
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        itemStatusObservation = nil
        presentationSizeObservation = nil
        guard let item else { return }

        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay:
                    self.itemReady = true
                    self.updateControls()
                    self.recordPresentationSize(of: item)
                case .failed:
                    self.failVideo(item.error?.localizedDescription ?? "Video failed to load.")
                default:
                    self.itemReady = false
                    self.updateControls()
                }
            }
        }
        presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self, weak item] _, _ in
            DispatchQueue.main.async {
                guard let self, let item, self.player.currentItem === item else { return }
                self.recordPresentationSize(of: item)
            }
        }
    }

    private func recordPresentationSize(of item: AVPlayerItem) {
        let size = item.presentationSize
        guard item.status == .readyToPlay, size.width > 0, size.height > 0 else { return }
        let sizeText = "\(Int(size.width))x\(Int(size.height))"
        guard lastRecordedSize != sizeText else { return }
        lastRecordedSize = sizeText
        record("ratio=\(selectedAspect.title) presentationSize=\(sizeText)")
    }

    private func loadVideo(for aspect: AspectRatio) {
        guard pipController?.isPictureInPictureActive != true else { return }
        selectedAspect = aspect
        UserDefaults.standard.set(aspect.rawValue, forKey: aspectPreferenceKey)
        ratioPicker.selectedSegmentIndex = AspectRatio.displayOrder.firstIndex(of: aspect) ?? 0
        ratioPicker.accessibilityValue = aspect.title
        itemReady = false
        videoError = nil
        pipError = nil
        lastRecordedSize = nil
        itemStatusObservation = nil
        presentationSizeObservation = nil
        looperStatusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.removeAllItems()
        updateControls()

        guard let url = Bundle.main.url(forResource: aspect.basename, withExtension: "mp4") else {
            failVideo("Missing \(aspect.basename).mp4 in the app bundle.")
            return
        }
        let newLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        looper = newLooper
        looperStatusObservation = newLooper.observe(\.status, options: [.initial, .new]) { [weak self, weak newLooper] _, _ in
            DispatchQueue.main.async {
                guard let self, let newLooper, self.looper === newLooper else { return }
                if newLooper.status == .failed {
                    self.failVideo(newLooper.error?.localizedDescription ?? "Video loop failed.")
                }
            }
        }
        record("selected ratio=\(aspect.title) asset=\(aspect.basename).mp4")
        player.play()
    }

    private func failVideo(_ description: String) {
        guard videoError != description else { return }
        videoError = description
        itemReady = false
        record("ratio=\(selectedAspect.title) error=\(description)")
        updateControls()
    }

    private func updateControls() {
        let active = pipController?.isPictureInPictureActive ?? false
        let supported = AVPictureInPictureController.isPictureInPictureSupported() && pipController != nil
        let possible = pipController?.isPictureInPicturePossible ?? false
        ratioPicker.isEnabled = !active
        let buttonTitle = active ? "Stop PiP" : "Start PiP"
        if startButton.configuration?.title != buttonTitle {
            startButton.configuration?.title = buttonTitle
        }
        startButton.accessibilityLabel = active ? "Stop Picture in Picture" : "Start Picture in Picture"
        startButton.isEnabled = active || (itemReady && possible && videoError == nil)

        let message: String
        if active {
            message = "Stop PiP to change video shape."
        } else if let videoError {
            message = videoError
        } else if let pipError {
            message = pipError
        } else if !supported {
            message = "PiP unavailable on this simulator."
        } else if !itemReady {
            message = "Preparing video…"
        } else if possible {
            message = "\(selectedAspect.title) · Ready for PiP"
        } else {
            message = "\(selectedAspect.title) · Waiting for PiP"
        }
        guard statusLabel.text != message else { return }
        let change = { self.statusLabel.text = message }
        if UIAccessibility.isReduceMotionEnabled {
            change()
        } else {
            UIView.transition(with: statusLabel, duration: 0.2, options: .transitionCrossDissolve, animations: change)
        }
    }

    @objc private func aspectChanged() {
        guard AspectRatio.displayOrder.indices.contains(ratioPicker.selectedSegmentIndex) else { return }
        let aspect = AspectRatio.displayOrder[ratioPicker.selectedSegmentIndex]
        loadVideo(for: aspect)
    }

    @objc private func togglePiP() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            record("Stop PiP tapped; ratio=\(selectedAspect.title)")
            pipController.stopPictureInPicture()
        } else if itemReady && pipController.isPictureInPicturePossible {
            pipError = nil
            record("Start PiP tapped; ratio=\(selectedAspect.title)")
            pipController.startPictureInPicture()
        }
    }

    private func record(_ message: String) {
        let line = "\(Date()): \(message)\n"
        print("PiPProbe: \(message)")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.log")
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path), let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        record("delegate didStartPictureInPicture ratio=\(selectedAspect.title)")
        updateControls()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        record("delegate failedToStartPictureInPicture ratio=\(selectedAspect.title) error=\(error.localizedDescription)")
        pipError = error.localizedDescription
        updateControls()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        record("delegate didStopPictureInPicture ratio=\(selectedAspect.title)")
        updateControls()
    }
}
