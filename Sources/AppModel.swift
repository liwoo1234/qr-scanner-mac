import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ScanRecord: Identifiable, Codable, Equatable {
    var id = UUID()
    var raw: String
    var date = Date()
    var content: QRContent { QRContent.parse(raw) }
}

struct QRAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let run: () -> Void
}

@MainActor
final class AppModel: ObservableObject {
    let scanner = CameraScanner()

    @Published var current: ScanRecord?
    @Published private(set) var scanning = true
    @Published private(set) var history: [ScanRecord] = []
    @Published private(set) var toast: String?

    // 설정 (UserDefaults에 저장)
    @Published var autoOpenWeb: Bool { didSet { UserDefaults.standard.set(autoOpenWeb, forKey: "autoOpenWeb") } }
    @Published var playSound: Bool { didSet { UserDefaults.standard.set(playSound, forKey: "playSound") } }
    @Published var mirror: Bool { didSet { UserDefaults.standard.set(mirror, forKey: "mirror") } }
    @Published var pauseInBackground: Bool { didSet { UserDefaults.standard.set(pauseInBackground, forKey: "pauseInBackground") } }

    private var toastTask: Task<Void, Never>?
    private var started = false
    private let maxHistory = 300

    init() {
        let d = UserDefaults.standard
        autoOpenWeb = d.bool(forKey: "autoOpenWeb")
        playSound = d.object(forKey: "playSound") as? Bool ?? true
        mirror = d.object(forKey: "mirror") as? Bool ?? true
        pauseInBackground = d.object(forKey: "pauseInBackground") as? Bool ?? true
        if let data = d.data(forKey: "history"),
           let items = try? JSONDecoder().decode([ScanRecord].self, from: data) {
            history = items
        }

        scanner.onDetect = { [weak self] value in self?.handleScan(value, fromCamera: true) }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pauseInBackground else { return }
                self.scanner.suspend()
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scanner.resume() }
        }

        AppDelegate.openHandler = { [weak self] urls in self?.openFiles(urls) }
        if !AppDelegate.pending.isEmpty {
            let urls = AppDelegate.pending
            AppDelegate.pending = []
            DispatchQueue.main.async { self.openFiles(urls) }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        scanner.start()
    }

    // MARK: - 스캔 처리

    func handleScan(_ raw: String, fromCamera: Bool) {
        let record = ScanRecord(raw: raw)
        current = record
        addToHistory(raw)
        if playSound { NSSound(named: "Tink")?.play() }

        if fromCamera, autoOpenWeb, case .web(let url) = record.content {
            open(url)
            showToast("\(record.content.title) 열기")
            // 자동 열기 모드에서는 계속 스캔
        } else if fromCamera {
            scanning = false
            scanner.pauseDetection()
        }
    }

    func resumeScanning() {
        current = nil
        scanning = true
        scanner.resumeDetection()
    }

    func show(_ record: ScanRecord) {
        current = record
        scanning = false
        scanner.pauseDetection()
    }

    private func addToHistory(_ raw: String) {
        if let first = history.first, first.raw == raw, Date().timeIntervalSince(first.date) < 60 {
            history[0].date = Date()
        } else {
            history.insert(ScanRecord(raw: raw), at: 0)
            if history.count > maxHistory { history.removeLast(history.count - maxHistory) }
        }
        saveHistory()
    }

    func deleteHistory(_ record: ScanRecord) {
        history.removeAll { $0.id == record.id }
        saveHistory()
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: "history")
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = text }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self.toast = nil }
        }
    }

    // MARK: - 동작

    func actions(for record: ScanRecord) -> [QRAction] {
        let raw = record.raw
        switch record.content {
        case .web(let url):
            return [
                QRAction(title: "브라우저에서 열기", icon: "safari") { self.open(url) },
                QRAction(title: "링크 복사", icon: "doc.on.doc") { self.copy(url.absoluteString) },
            ]
        case .email(let address, let subject, let body):
            var comps = URLComponents()
            comps.scheme = "mailto"
            comps.path = address
            var items: [URLQueryItem] = []
            if let subject { items.append(URLQueryItem(name: "subject", value: subject)) }
            if let body { items.append(URLQueryItem(name: "body", value: body)) }
            if !items.isEmpty { comps.queryItems = items }
            return [
                QRAction(title: "메일 쓰기", icon: "square.and.pencil") { if let u = comps.url { self.open(u) } },
                QRAction(title: "주소 복사", icon: "doc.on.doc") { self.copy(address) },
            ]
        case .phone(let number):
            let digits = number.filter { $0.isNumber || $0 == "+" }
            return [
                QRAction(title: "전화 걸기 (FaceTime)", icon: "phone.fill") {
                    if let u = URL(string: "tel:" + digits) { self.open(u) }
                },
                QRAction(title: "번호 복사", icon: "doc.on.doc") { self.copy(number) },
            ]
        case .sms(let number, let body):
            let digits = number.filter { $0.isNumber || $0 == "+" }
            var acts = [
                QRAction(title: "메시지 보내기", icon: "message.fill") {
                    var s = "sms:" + digits
                    if let body, let enc = body.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                        s += "&body=" + enc
                    }
                    if let u = URL(string: s) { self.open(u) }
                },
                QRAction(title: "번호 복사", icon: "doc.on.doc") { self.copy(number) },
            ]
            if let body { acts.append(QRAction(title: "내용 복사", icon: "text.quote") { self.copy(body) }) }
            return acts
        case .wifi(let info):
            var acts = [QRAction(title: "Wi-Fi 연결", icon: "wifi") { self.connectWiFi(info) }]
            if let pw = info.password {
                acts.append(QRAction(title: "비밀번호 복사", icon: "key.fill") { self.copy(pw, message: "비밀번호를 복사했습니다") })
            }
            acts.append(QRAction(title: "네트워크 이름 복사", icon: "doc.on.doc") { self.copy(info.ssid) })
            return acts
        case .geo(let lat, let lon, let label):
            var comps = URLComponents(string: "https://maps.apple.com/")!
            comps.queryItems = [
                URLQueryItem(name: "ll", value: "\(lat),\(lon)"),
                URLQueryItem(name: "q", value: label ?? "QR 위치"),
            ]
            return [
                QRAction(title: "지도에서 열기", icon: "map.fill") { if let u = comps.url { self.open(u) } },
                QRAction(title: "좌표 복사", icon: "doc.on.doc") { self.copy("\(lat), \(lon)") },
            ]
        case .contact(_, let vcard):
            return [
                QRAction(title: "연락처에 추가", icon: "person.crop.circle.badge.plus") { self.openTemp(vcard, ext: "vcf") },
                QRAction(title: "원문 복사", icon: "doc.on.doc") { self.copy(raw) },
            ]
        case .event(_, let ics):
            return [
                QRAction(title: "캘린더에 추가", icon: "calendar.badge.plus") {
                    var text = ics
                    if !text.uppercased().hasPrefix("BEGIN:VCALENDAR") {
                        text = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//QRScanner//KO\r\n\(text)\r\nEND:VCALENDAR"
                    }
                    self.openTemp(text, ext: "ics")
                },
                QRAction(title: "원문 복사", icon: "doc.on.doc") { self.copy(raw) },
            ]
        case .appLink(let url):
            return [
                QRAction(title: "앱에서 열기", icon: "arrow.up.forward.app") { self.open(url) },
                QRAction(title: "링크 복사", icon: "doc.on.doc") { self.copy(raw) },
            ]
        case .text(let text):
            return [
                QRAction(title: "텍스트 복사", icon: "doc.on.doc") { self.copy(text) },
                QRAction(title: "웹에서 검색", icon: "magnifyingglass") {
                    var comps = URLComponents(string: "https://www.google.com/search")!
                    comps.queryItems = [URLQueryItem(name: "q", value: text)]
                    if let u = comps.url { self.open(u) }
                },
            ]
        }
    }

    func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            showToast("이 링크를 열 수 있는 앱이 없습니다")
        }
    }

    func copy(_ text: String, message: String = "클립보드에 복사했습니다") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(message)
    }

    private func openTemp(_ text: String, ext: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qr-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            open(url)
        } catch {
            showToast("파일을 만들 수 없습니다: \(error.localizedDescription)")
        }
    }

    private func connectWiFi(_ info: WiFiInfo) {
        showToast("“\(info.ssid)”에 연결하는 중…")
        Task.detached {
            let error = WiFiConnector.connect(ssid: info.ssid, password: info.password)
            await MainActor.run {
                if let error {
                    if let pw = info.password {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(pw, forType: .string)
                    }
                    if let u = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
                        NSWorkspace.shared.open(u)
                    }
                    self.showToast("자동 연결 실패 (\(error)) — 비밀번호를 복사했으니 Wi-Fi 설정에서 선택하세요")
                } else {
                    self.showToast("“\(info.ssid)”에 연결했습니다")
                }
            }
        }
    }

    // MARK: - 이미지에서 QR 읽기

    func openImagePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "QR 코드가 들어있는 이미지를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            openFiles([url])
        }
    }

    func openFiles(_ urls: [URL]) {
        guard let url = urls.first else { return }
        guard let image = NSImage(contentsOf: url) else {
            showToast("이미지를 읽을 수 없습니다")
            return
        }
        scanImage(image)
    }

    func scanPasteboard() {
        if let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage {
            scanImage(image)
        } else {
            showToast("클립보드에 이미지가 없습니다")
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.openFiles([url]) }
            }
            return true
        }
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                guard let image = obj as? NSImage, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                Task { @MainActor in self.scanCGImage(cg) }
            }
            return true
        }
        return false
    }

    func scanImage(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showToast("이미지를 읽을 수 없습니다")
            return
        }
        scanCGImage(cg)
    }

    private func scanCGImage(_ cg: CGImage) {
        Task.detached(priority: .userInitiated) {
            let values = CameraScanner.decode(cg)
            await MainActor.run {
                guard let first = values.first else {
                    self.showToast("이미지에서 QR 코드를 찾지 못했습니다")
                    return
                }
                self.handleScan(first, fromCamera: false)
                self.scanning = false
                self.scanner.pauseDetection()
                if values.count > 1 { self.showToast("QR \(values.count)개 중 첫 번째를 표시합니다") }
            }
        }
    }
}

/// networksetup으로 Wi-Fi에 연결 (실패 시 오류 문자열 반환)
enum WiFiConnector {
    static func connect(ssid: String, password: String?) -> String? {
        guard let device = wifiDevice() else { return "Wi-Fi 장치를 찾을 수 없음" }
        var args = ["-setairportnetwork", device, ssid]
        if let password { args.append(password) }
        let (status, out) = run("/usr/sbin/networksetup", args)
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if status != 0 || !trimmed.isEmpty { return trimmed.isEmpty ? "오류 코드 \(status)" : trimmed }
        return nil
    }

    private static func wifiDevice() -> String? {
        let (_, out) = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = out.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") {
                return String(lines[i + 1].dropFirst("Device: ".count))
            }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
