import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Allow `EasyMovTrim <file>` from the command line.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first, FileManager.default.fileExists(atPath: path) {
            AppModel.shared.open(url: URL(fileURLWithPath: path))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            AppModel.shared.open(url: url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MediaImporter.cleanupTemp()
    }
}

struct EasyMovTrimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("EasyMovTrim", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 760)
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("動画を開く…") { model.showOpenPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("再生") {
                Button("再生 / 一時停止（Space）") { model.togglePlay() }
                Button("範囲を再生") { model.playRange() }
                Divider()
                Button("現在位置を開始点に（I）") { model.setInToCurrent() }
                Button("現在位置を終了点に（O）") { model.setOutToCurrent() }
                Button("範囲をリセット") { model.resetRange() }
            }
        }
    }
}
