import Foundation
import AVFoundation
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case ffmpegMissing(String)
    case ffmpegFailed(String)
    case noVideo

    var errorDescription: String? {
        switch self {
        case .ffmpegMissing(let ext):
            return "「.\(ext)」形式の読み込みには ffmpeg が必要です。アプリ内に同梱するか、Homebrew で ffmpeg をインストールしてください（brew install ffmpeg）。"
        case .ffmpegFailed(let log):
            return "ffmpeg での変換に失敗しました。\n\n\(log)"
        case .noVideo:
            return "映像トラックが見つかりません。"
        }
    }
}

/// Makes any input file playable by AVFoundation, converting through ffmpeg when needed.
enum MediaImporter {
    /// Containers commonly handled through ffmpeg (AVFoundation types are covered by UTTypes).
    static let extraExtensions = [
        "mkv", "webm", "avi", "flv", "f4v", "wmv", "asf", "mts", "m2ts", "ts", "m2t", "mpg", "mpeg",
        "m2v", "vob", "ogv", "ogg", "3gp", "3g2", "rm", "rmvb", "divx", "xvid", "mxf", "dv", "y4m", "nut", "gif",
    ]

    static var openableTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent, .mpeg4Movie, .quickTimeMovie, .avi, .mpeg, .mpeg2Video]
        for ext in extraExtensions {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    static var tempDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EasyMovTrim", isDirectory: true)
    }

    static func cleanupTemp() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: Tool lookup

    static func toolURL(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("bin/\(name)"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(name)"))
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"] {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent(name))
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Capability check

    static func isNativelyPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isPlayable) else { return false }
            let videos = try await asset.loadTracks(withMediaType: .video)
            guard let video = videos.first, try await video.load(.isPlayable) else { return false }
            let audios = try await asset.loadTracks(withMediaType: .audio)
            if let audio = audios.first, !(try await audio.load(.isPlayable)) { return false }
            return true
        } catch {
            return false
        }
    }

    static func primaryAudioTrack(_ asset: AVAsset) async throws -> AVAssetTrack? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        for t in tracks where try await t.load(.isEnabled) {
            return t
        }
        return tracks.first
    }

    // MARK: Prepare

    struct Prepared {
        let url: URL
        let converted: Bool
    }

    /// Returns a URL AVFoundation can play. `progress` receives (fraction or nil, message).
    static func prepare(
        url: URL,
        progress: @escaping (Double?, String) -> Void,
        registerProcess: @escaping (Process) -> Void
    ) async throws -> Prepared {
        if await isNativelyPlayable(url) {
            return Prepared(url: url, converted: false)
        }
        guard let ffmpeg = toolURL("ffmpeg") else {
            throw ImportError.ffmpegMissing(url.pathExtension.lowercased())
        }
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let probe = await probe(url)
        let duration = probe?.duration

        // 1) Try a fast remux when the codecs are already AVFoundation friendly.
        if let probe, probe.canRemux {
            progress(nil, "コンテナを変換しています…")
            let out = tempDirectory.appendingPathComponent(UUID().uuidString + ".mov")
            var args = ["-hide_banner", "-y", "-i", url.path, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
                        "-sn", "-dn", "-avoid_negative_ts", "make_zero"]
            if probe.videoCodec == "hevc" { args += ["-tag:v", "hvc1"] }
            args += ["-progress", "pipe:1", "-nostats", out.path]
            if (try? await run(ffmpeg, args, duration: duration, progress: { progress($0, "コンテナを変換しています…") }, registerProcess: registerProcess)) != nil,
               await isNativelyPlayable(out) {
                return Prepared(url: out, converted: true)
            }
            try? FileManager.default.removeItem(at: out)
            try Task.checkCancellation()
        }

        // 2) Full transcode to H.264 + PCM in a QuickTime container.
        let out = tempDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        var filters: [String] = []
        if probe?.interlaced == true { filters.append("bwdif") }
        filters.append("scale=trunc(iw*sar/2)*2:trunc(ih/2)*2")
        filters.append("setsar=1")
        filters.append("format=yuv420p")
        var base = ["-hide_banner", "-y", "-i", url.path, "-map", "0:v:0", "-map", "0:a:0?", "-sn", "-dn",
                    "-vf", filters.joined(separator: ","), "-c:a", "pcm_s16le"]
        if let ch = probe?.audioChannels, ch > 2 { base += ["-ac", "2"] }
        base += ["-avoid_negative_ts", "make_zero"]
        let tail = ["-progress", "pipe:1", "-nostats", out.path]

        let encoders: [[String]] = [
            ["-c:v", "h264_videotoolbox", "-q:v", "75", "-allow_sw", "1"],
            ["-c:v", "libx264", "-preset", "veryfast", "-crf", "15"],
            ["-c:v", "h264_videotoolbox", "-b:v", "40M"],
        ]
        var lastError: Error = ImportError.ffmpegFailed("")
        for enc in encoders {
            try Task.checkCancellation()
            do {
                try await run(ffmpeg, base + enc + tail, duration: duration,
                              progress: { progress($0, "動画を変換しています…") }, registerProcess: registerProcess)
                if await isNativelyPlayable(out) {
                    return Prepared(url: out, converted: true)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        try? FileManager.default.removeItem(at: out)
        throw lastError
    }

    // MARK: ffprobe

    struct ProbeResult {
        var duration: Double?
        var videoCodec: String?
        var audioCodec: String?
        var audioChannels: Int?
        var interlaced = false

        var canRemux: Bool {
            let videoOK = ["h264", "hevc", "prores", "mjpeg"].contains(videoCodec ?? "")
            let audioOK: Bool
            if let a = audioCodec {
                audioOK = ["aac", "alac", "mp3"].contains(a) || a.hasPrefix("pcm_")
            } else {
                audioOK = true
            }
            return videoOK && audioOK && !interlaced
        }
    }

    static func probe(_ url: URL) async -> ProbeResult? {
        guard let ffprobe = toolURL("ffprobe") else { return nil }
        let args = ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path]
        guard let data = try? await capture(ffprobe, args),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result = ProbeResult()
        if let format = json["format"] as? [String: Any], let d = format["duration"] as? String {
            result.duration = Double(d)
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String
            let codec = stream["codec_name"] as? String
            if type == "video", result.videoCodec == nil {
                result.videoCodec = codec
                if let fo = stream["field_order"] as? String, ["tt", "bb", "tb", "bt"].contains(fo) {
                    result.interlaced = true
                }
            } else if type == "audio", result.audioCodec == nil {
                result.audioCodec = codec
                result.audioChannels = stream["channels"] as? Int
            }
        }
        return result
    }

    // MARK: Process helpers

    private final class OutputCollector {
        private let lock = UnfairLock()
        private var data = Data()
        private var lineBuffer = ""

        func append(_ chunk: Data) {
            lock.withLock {
                data.append(chunk)
                if data.count > 16_000 { data = data.suffix(8_000) }
            }
        }

        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

        /// Splits progress output into lines.
        func lines(from chunk: Data) -> [String] {
            lock.withLock {
                lineBuffer += String(decoding: chunk, as: UTF8.self)
                var parts = lineBuffer.components(separatedBy: "\n")
                lineBuffer = parts.removeLast()
                return parts
            }
        }
    }

    static func run(
        _ tool: URL, _ args: [String], duration: Double?,
        progress: @escaping (Double?) -> Void,
        registerProcess: @escaping (Process) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        let stderr = OutputCollector()
        let stdout = OutputCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in stdout.lines(from: chunk) where line.hasPrefix("out_time_us=") {
                if let us = Double(line.dropFirst("out_time_us=".count)), let duration, duration > 0 {
                    progress((us / 1_000_000 / duration).clamped(0, 1))
                }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { stderr.append(chunk) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    if p.terminationStatus == 0 {
                        cont.resume()
                    } else if p.terminationReason == .uncaughtSignal {
                        cont.resume(throwing: CancellationError())
                    } else {
                        let log = stderr.text.split(separator: "\n").suffix(8).joined(separator: "\n")
                        cont.resume(throwing: ImportError.ffmpegFailed(log))
                    }
                }
                do {
                    try process.run()
                    registerProcess(process)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    static func capture(_ tool: URL, _ args: [String]) async throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: data)
            }
        }
    }
}
