import Foundation
import AVFoundation

/// Command-line export (no GUI), useful for batch work and testing:
///   EasyMovTrim --export <input> <output.mp4> [--in 1.5] [--out 9.0] [--quality light|high]
///               [--fadein 1.0] [--fadeout 2.0] [--volume -6] [--plugin "AUDelay"]
///   EasyMovTrim --list-plugins
enum Headless {
    static func value(_ args: [String], _ key: String) -> String? {
        guard let i = args.firstIndex(of: key), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        exit(1)
    }

    static func listPlugins() -> Never {
        for c in PluginCatalog.effectComponents() {
            print("\(c.manufacturerName)\t\(c.name)")
        }
        exit(0)
    }

    static func runExport(_ args: [String]) -> Never {
        guard let i = args.firstIndex(of: "--export"), i + 2 < args.count else {
            fail("usage: EasyMovTrim --export <input> <output.mp4> [options]")
        }
        let input = URL(fileURLWithPath: args[i + 1])
        let output = URL(fileURLWithPath: args[i + 2])
        let quality: ExportQuality = value(args, "--quality") == "light" ? .light : .high

        Task {
            do {
                let prepared = try await MediaImporter.prepare(url: input, progress: { p, msg in
                    if let p { FileHandle.standardError.write(String(format: "\r%@ %3.0f%%", msg, p * 100).data(using: .utf8)!) }
                }, registerProcess: { _ in })
                if prepared.converted { FileHandle.standardError.write("\nconverted via ffmpeg\n".data(using: .utf8)!) }
                let asset = AVURLAsset(url: prepared.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                let duration = try await asset.load(.duration).seconds
                let start = Double(value(args, "--in") ?? "") ?? 0
                let end = Double(value(args, "--out") ?? "") ?? duration

                let params = AudioParams()
                let chain = EffectChain()
                params.update {
                    $0.gain = Decibel.toLinear(Double(value(args, "--volume") ?? "") ?? 0)
                    if let fi = Double(value(args, "--fadein") ?? "") {
                        $0.fadeInEnabled = true
                        $0.fadeInDuration = AppModel.normalizeFade(fi)
                    }
                    if let fo = Double(value(args, "--fadeout") ?? "") {
                        $0.fadeOutEnabled = true
                        $0.fadeOutDuration = AppModel.normalizeFade(fo)
                    }
                    $0.trimStart = start
                    $0.trimEnd = end
                }
                if let name = value(args, "--plugin") {
                    guard let comp = PluginCatalog.effectComponents().first(where: { $0.name == name }) else {
                        fail("plugin not found: \(name)")
                    }
                    let unit = try await PluginCatalog.instantiate(comp)
                    chain.add(EffectSlot(name: comp.name, manufacturer: comp.manufacturerName, avUnit: unit))
                    print("plugin: \(comp.manufacturerName) \(comp.name)")
                }

                let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60_000),
                                        end: CMTime(seconds: end, preferredTimescale: 60_000))
                let began = Date()
                try await VideoExporter().export(asset: asset, timeRange: range, quality: quality,
                                                 audioParams: params, chain: chain, to: output) { p in
                    FileHandle.standardError.write(String(format: "\rexport %3.0f%%", p * 100).data(using: .utf8)!)
                }
                print(String(format: "\ndone: %@ (%.1fs)", output.path, Date().timeIntervalSince(began)))
                MediaImporter.cleanupTemp()
                exit(0)
            } catch {
                MediaImporter.cleanupTemp()
                fail("\nerror: \(error.localizedDescription)")
            }
        }
        dispatchMain()
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--list-plugins") {
    Headless.listPlugins()
} else if arguments.contains("--export") {
    Headless.runExport(arguments)
} else {
    EasyMovTrimApp.main()
}
