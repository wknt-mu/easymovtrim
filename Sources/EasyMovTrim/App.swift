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
            HelpCommands()
        }

        Window("ライセンス情報", id: "licenses") {
            LicenseView()
        }
        .defaultSize(width: 720, height: 640)
    }
}

enum AppLinks {
    static let repository = URL(string: "https://github.com/wknt-mu/easymovtrim")!
    static let issues = URL(string: "https://github.com/wknt-mu/easymovtrim/issues")!
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("EasyMovTrim のサイト（GitHub）") { NSWorkspace.shared.open(AppLinks.repository) }
            Button("お問い合わせ・不具合報告…") { NSWorkspace.shared.open(AppLinks.issues) }
            Divider()
            Button("ライセンス情報") { openWindow(id: "licenses") }
        }
    }
}

/// Shows THIRD_PARTY_NOTICES.md and gives access to the bundled license texts.
struct LicenseView: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            return "Copyright © 2026 Naoto Iwaki — GPL-3.0-or-later\n\(AppLinks.repository.absoluteString)"
        }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            HStack {
                Button("ライセンス全文のフォルダを開く") {
                    if let res = Bundle.main.resourceURL {
                        NSWorkspace.shared.open(res.appendingPathComponent("licenses"))
                    }
                }
                Button("ソースコード（GitHub）") { NSWorkspace.shared.open(AppLinks.repository) }
                Spacer()
            }
            .padding([.horizontal, .bottom])
        }
    }
}
