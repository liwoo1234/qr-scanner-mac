import AVFoundation
import SwiftUI

// MARK: - 카메라 미리보기 (AppKit)

final class CameraPreviewNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    private let boxLayer = CAShapeLayer()
    private var overlay: QROverlay?
    var mirrored = true {
        didSet { if oldValue != mirrored { applyMirror(); redraw() } }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        root.addSublayer(previewLayer)
        boxLayer.fillColor = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        boxLayer.strokeColor = NSColor.systemGreen.cgColor
        boxLayer.lineWidth = 4
        boxLayer.lineJoin = .round
        root.addSublayer(boxLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        boxLayer.frame = bounds
        CATransaction.commit()
        applyMirror()
        redraw()
    }

    func applyMirror() {
        guard let c = previewLayer.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = mirrored
    }

    func update(_ o: QROverlay?) {
        overlay = o
        redraw()
    }

    /// Vision 좌표 → 화면 좌표 (aspect-fill + 좌우반전 고려)
    private func redraw() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        defer { CATransaction.commit() }
        guard let o = overlay, o.imageSize.width > 0, o.imageSize.height > 0 else {
            boxLayer.path = nil
            return
        }
        let W = o.imageSize.width, H = o.imageSize.height
        let w = bounds.width, h = bounds.height
        let s = max(w / W, h / H)
        let ox = (w - W * s) / 2, oy = (h - H * s) / 2
        let pts = o.points.map { p -> CGPoint in
            var x = ox + p.x * W * s
            let y = oy + p.y * H * s
            if mirrored { x = w - x }
            return CGPoint(x: x, y: y)
        }
        let path = CGMutablePath()
        path.addLines(between: pts)
        path.closeSubpath()
        boxLayer.path = path
    }
}

struct CameraPreview: NSViewRepresentable {
    let scanner: CameraScanner
    var mirrored: Bool
    var state: CameraScanner.State

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let v = CameraPreviewNSView(session: scanner.session)
        v.mirrored = mirrored
        scanner.onOverlay = { [weak v] o in v?.update(o) }
        return v
    }

    func updateNSView(_ v: CameraPreviewNSView, context: Context) {
        v.mirrored = mirrored
        v.applyMirror()
    }
}

// MARK: - 메인 화면

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            CameraPane(scanner: model.scanner)
                .frame(minWidth: 520)
            Divider()
            Sidebar()
                .frame(width: 350)
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar { Toolbar(scanner: model.scanner) }
        .onAppear { model.start() }
    }
}

struct Toolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @ObservedObject var scanner: CameraScanner

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if scanner.devices.count > 1 {
                Picker("카메라", selection: Binding(
                    get: { scanner.selectedDeviceID ?? "" },
                    set: { scanner.select(deviceID: $0) }
                )) {
                    ForEach(scanner.devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(d.uniqueID)
                    }
                }
                .help("카메라 선택")
            }
            Toggle(isOn: $model.mirror) {
                Label("좌우 반전", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("미리보기 좌우 반전")
            Button {
                model.openImagePanel()
            } label: {
                Label("이미지에서 읽기", systemImage: "photo.badge.magnifyingglass")
            }
            .help("이미지 파일에서 QR 읽기 (⌘O)")
        }
    }
}

// MARK: - 카메라 영역

struct CameraPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var scanner: CameraScanner
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            Color.black

            switch scanner.state {
            case .running, .stopped:
                CameraPreview(scanner: scanner, mirrored: model.mirror, state: scanner.state)
            case .idle, .requesting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("카메라 권한을 확인하는 중…").foregroundStyle(.white.opacity(0.8))
                }
            case .denied:
                MessageView(icon: "video.slash.fill",
                            title: "카메라 접근 권한이 필요합니다",
                            detail: "시스템 설정 › 개인정보 보호 및 보안 › 카메라에서 ‘QR 스캐너’를 켜 주세요.",
                            buttonTitle: "시스템 설정 열기") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(u)
                    }
                }
            case .noCamera:
                MessageView(icon: "video.badge.exclamationmark", title: "사용할 수 있는 카메라가 없습니다",
                            detail: "이미지 파일을 끌어다 놓아도 QR을 읽을 수 있어요.", buttonTitle: nil, action: {})
            case .error(let msg):
                MessageView(icon: "exclamationmark.triangle.fill", title: "카메라 오류", detail: msg,
                            buttonTitle: "다시 시도") { scanner.start() }
            }

            if scanner.state == .running {
                ViewfinderCorners()
                    .stroke(model.scanning ? Color.white.opacity(0.85) : Color.green,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .frame(width: 250, height: 250)
                    .shadow(color: .black.opacity(0.4), radius: 6)
                    .animation(.easeInOut(duration: 0.2), value: model.scanning)
                    .allowsHitTesting(false)
            }

            if scanner.state == .stopped {
                Label("앱이 비활성 상태라 카메라를 잠시 껐습니다", systemImage: "pause.circle.fill")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            VStack {
                if let toast = model.toast {
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 16)
                }
                Spacer()
                StatusPill()
                    .padding(.bottom, 20)
            }

            if dropTargeted {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [12, 8]))
                    .background(Color.accentColor.opacity(0.15))
                    .overlay(Label("놓으면 이미지에서 QR을 읽습니다", systemImage: "photo")
                        .font(.title3.weight(.semibold)).foregroundStyle(.white))
                    .padding(12)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { model.handleDrop($0) }
    }
}

struct StatusPill: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.scanning {
                Image(systemName: "qrcode.viewfinder")
                Text("QR 코드를 카메라 앞에 비춰 주세요")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("인식 완료")
                Button("다시 스캔") { model.resumeScanning() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}

struct MessageView: View {
    let icon: String
    let title: String
    let detail: String
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.white.opacity(0.8))
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.7)).frame(maxWidth: 360)
            if let buttonTitle {
                Button(buttonTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
    }
}

struct ViewfinderCorners: Shape {
    func path(in r: CGRect) -> Path {
        let l = r.width * 0.2
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

// MARK: - 오른쪽 사이드바

extension QRContent {
    var tint: Color {
        switch self {
        case .web: .blue
        case .email: .indigo
        case .phone: .green
        case .sms: .mint
        case .wifi: .teal
        case .geo: .red
        case .contact: .orange
        case .event: .pink
        case .appLink: .purple
        case .text: .gray
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let record = model.current {
                    ResultCard(record: record)
                        .id(record.id)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    EmptyHint()
                }
            }
            .padding(16)
            .animation(.spring(duration: 0.3), value: model.current)

            Divider()

            HStack {
                Text("스캔 기록").font(.headline)
                Text("\(model.history.count)").foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                if !model.history.isEmpty {
                    Button("모두 지우기") { confirmClear = true }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if model.history.isEmpty {
                VStack {
                    Spacer()
                    Text("아직 스캔한 QR 코드가 없습니다").foregroundStyle(.secondary).font(.callout)
                    Spacer()
                }
            } else {
                List(model.history) { item in
                    HistoryRow(record: item, selected: model.current?.raw == item.raw)
                        .contentShape(Rectangle())
                        .onTapGesture { model.show(item) }
                        .contextMenu {
                            ForEach(model.actions(for: item)) { a in
                                Button { a.run() } label: { Label(a.title, systemImage: a.icon) }
                            }
                            Divider()
                            Button("기록에서 삭제", role: .destructive) { model.deleteHistory(item) }
                        }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }

            Divider()
            Toggle(isOn: $model.autoOpenWeb) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("웹 링크 바로 열기")
                    Text("인식하면 확인 없이 브라우저로 엽니다").font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("스캔 기록을 모두 지울까요?", isPresented: $confirmClear) {
            Button("모두 지우기", role: .destructive) { model.clearHistory() }
        }
    }
}

struct EmptyHint: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("QR 코드를 기다리는 중").font(.headline)
            Text("카메라에 QR을 비추거나, 이미지 파일을 왼쪽 화면에 끌어다 놓으세요.\n웹사이트 · Wi-Fi · 연락처 · 일정 · 전화 · 문자 · 위치를 인식합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
    }
}

struct ResultCard: View {
    @EnvironmentObject var model: AppModel
    let record: ScanRecord

    var body: some View {
        let content = record.content
        let actions = model.actions(for: record)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: content.icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(content.tint.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.typeName).font(.caption).foregroundStyle(.secondary)
                    Text(content.title).font(.headline).lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }

            if case .wifi(let w) = content {
                VStack(alignment: .leading, spacing: 4) {
                    LabeledContent("보안", value: w.security ?? "없음")
                    LabeledContent("비밀번호", value: w.password ?? "없음")
                    if w.hidden { LabeledContent("숨김 네트워크", value: "예") }
                }
                .font(.callout)
                .textSelection(.enabled)
            }

            ScrollView {
                Text(record.raw)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))

            ForEach(content.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let primary = actions.first {
                Button {
                    primary.run()
                } label: {
                    Label(primary.title, systemImage: primary.icon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }

            ForEach(actions.dropFirst()) { a in
                Button {
                    a.run()
                } label: {
                    Label(a.title, systemImage: a.icon).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            if !model.scanning {
                Button {
                    model.resumeScanning()
                } label: {
                    Label("다시 스캔", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
                .keyboardShortcut("r")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
    }
}

struct HistoryRow: View {
    let record: ScanRecord
    let selected: Bool

    var body: some View {
        let c = record.content
        HStack(spacing: 10) {
            Image(systemName: c.icon)
                .font(.callout)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(c.tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                Text(record.date, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 설정

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("스캔") {
                Toggle("웹 링크는 인식 즉시 브라우저로 열기", isOn: $model.autoOpenWeb)
                Toggle("인식할 때 소리 내기", isOn: $model.playSound)
            }
            Section("카메라") {
                Toggle("미리보기 좌우 반전 (거울 모드)", isOn: $model.mirror)
                Toggle("다른 앱을 쓰는 동안 카메라 끄기", isOn: $model.pauseInBackground)
            }
            Section("기록") {
                LabeledContent("저장된 기록", value: "\(model.history.count)개")
                Button("기록 모두 지우기", role: .destructive) { model.clearHistory() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
