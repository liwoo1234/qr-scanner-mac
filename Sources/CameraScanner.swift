import AVFoundation
import AppKit
import Vision

/// 카메라 프레임 위에 그릴 QR 위치 (Vision 정규화 좌표, 원점 왼쪽 아래)
struct QROverlay {
    var points: [CGPoint]
    var imageSize: CGSize
}

/// 맥북 전면(FaceTime) 카메라로 영상을 받아 Vision으로 QR 코드를 찾는 클래스
final class CameraScanner: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: Equatable {
        case idle, requesting, denied, noCamera, running, stopped
        case error(String)
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .idle
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var selectedDeviceID: String?

    /// 새 QR 코드를 인식했을 때 (메인 스레드)
    var onDetect: (@MainActor (String) -> Void)?
    /// 미리보기 위 강조 박스 갱신 (메인 스레드)
    var onOverlay: (@MainActor (QROverlay?) -> Void)?

    private let sessionQueue = DispatchQueue(label: "qrscanner.session")
    private let videoQueue = DispatchQueue(label: "qrscanner.video", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private var configured = false  // sessionQueue 전용

    // videoQueue 전용 상태
    private var paused = false
    private var lastValue: String?
    private var lastSeen = Date.distantPast
    private var frameIndex = 0
    private var overlayVisible = false
    private lazy var request: VNDetectBarcodesRequest = {
        let r = VNDetectBarcodesRequest()
        r.symbologies = [.qr, .microQR]
        return r
    }()

    /// 같은 코드는 이 시간 동안 화면에서 사라졌다가 다시 나타나야 재인식
    private let repeatInterval: TimeInterval = 3

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        }
        nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            let old = self.selectedDeviceID
            self.refreshDevices()
            if old != self.selectedDeviceID { self.configureAndRun() }
        }
    }

    // MARK: - 시작 / 정지

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refreshDevices()
            configureAndRun()
        case .notDetermined:
            state = .requesting
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.start() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func select(deviceID: String) {
        guard deviceID != selectedDeviceID else { return }
        selectedDeviceID = deviceID
        configureAndRun()
    }

    /// 앱이 비활성일 때 카메라(녹색 LED)를 끔
    func suspend() {
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
            self.setState(.stopped)
        }
    }

    func resume() {
        sessionQueue.async {
            guard self.configured, !self.session.isRunning else { return }
            self.session.startRunning()
            self.setState(.running)
        }
    }

    /// 인식은 잠시 멈추지만 영상과 강조 박스는 계속 표시
    func pauseDetection() { videoQueue.async { self.paused = true } }
    func resumeDetection() { videoQueue.async { self.paused = false } }

    private func refreshDevices() {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        devices = found
        if selectedDeviceID == nil || !found.contains(where: { $0.uniqueID == selectedDeviceID }) {
            // 맥북 내장 FaceTime 카메라를 우선 선택
            selectedDeviceID = (found.first { $0.deviceType == .builtInWideAngleCamera } ?? found.first)?.uniqueID
        }
    }

    private func configureAndRun() {
        let id = selectedDeviceID
        sessionQueue.async { [self] in
            guard let id, let device = AVCaptureDevice(uniqueID: id) else {
                setState(.noCamera)
                return
            }
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else { throw NSError(domain: "QRScanner", code: 1) }
                session.addInput(input)
            } catch {
                session.commitConfiguration()
                setState(.error("카메라를 열 수 없습니다: \(error.localizedDescription)"))
                return
            }
            if session.canSetSessionPreset(.hd1280x720) {
                session.sessionPreset = .hd1280x720
            } else {
                session.sessionPreset = .high
            }
            if !session.outputs.contains(output) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: videoQueue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()
            configured = true
            if !session.isRunning { session.startRunning() }
            setState(.running)
        }
    }

    private func setState(_ s: State) {
        Task { @MainActor in self.state = s }
    }

    // MARK: - 프레임 처리

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameIndex &+= 1
        if frameIndex % 2 != 0 { return }  // 약 15fps만 분석
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        try? handler.perform([request])

        guard let obs = request.results?.first(where: { !($0.payloadStringValue ?? "").isEmpty }),
              let value = obs.payloadStringValue else {
            if overlayVisible {
                overlayVisible = false
                postOverlay(nil)
            }
            return
        }

        overlayVisible = true
        postOverlay(QROverlay(points: [obs.topLeft, obs.topRight, obs.bottomRight, obs.bottomLeft], imageSize: size))

        let now = Date()
        if value == lastValue, now.timeIntervalSince(lastSeen) < repeatInterval {
            lastSeen = now
            return
        }
        if paused { return }
        lastValue = value
        lastSeen = now
        Task { @MainActor in self.onDetect?(value) }
    }

    private func postOverlay(_ o: QROverlay?) {
        Task { @MainActor in self.onOverlay?(o) }
    }

    // MARK: - 이미지 파일에서 읽기

    static func decode(_ image: CGImage) -> [String] {
        let r = VNDetectBarcodesRequest()
        r.symbologies = [.qr, .microQR]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([r])
        var seen = Set<String>()
        return (r.results ?? []).compactMap { $0.payloadStringValue }.filter { seen.insert($0).inserted }
    }
}
