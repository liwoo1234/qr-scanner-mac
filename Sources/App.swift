import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Finder에서 이미지를 "다음으로 열기"하거나 Dock 아이콘에 끌어다 놓았을 때
    @MainActor static var openHandler: (([URL]) -> Void)?
    @MainActor static var pending: [URL] = []

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        if let handler = AppDelegate.openHandler { handler(urls) } else { AppDelegate.pending += urls }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct QRScannerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("QR 스캐너", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1060, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("이미지에서 QR 읽기…") { model.openImagePanel() }
                    .keyboardShortcut("o")
                Button("클립보드 이미지에서 QR 읽기") { model.scanPasteboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("스캔") {
                Button("다시 스캔") { model.resumeScanning() }
                    .keyboardShortcut("r")
                Toggle("웹 링크 바로 열기", isOn: $model.autoOpenWeb)
                Toggle("미리보기 좌우 반전", isOn: $model.mirror)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 440)
        }
    }
}
