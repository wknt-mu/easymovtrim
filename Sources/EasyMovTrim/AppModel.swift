import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var revealURL: URL?
}

/// Main application state. All members are used from the main thread.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let player = AVPlayer()
    let audioParams = AudioParams()
    let meterState = MeterState()
    let meter: MeterModel
    let chain = EffectChain()

    static let minimumRange = 0.1

    // Media
    @Published private(set) var asset: AVAsset?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameRate: Double = 30
    @Published private(set) var mediaInfo = ""
    @Published private(set) var hasAudio = false
    @Published private(set) var thumbnails: [NSImage] = []

    // Transport
    @Published var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published var loopRange = false

    // Trim
    @Published private(set) var inPoint: Double = 0
    @Published private(set) var outPoint: Double = 0

    // Audio
    @Published var volumeDB: Double = 0 { didSet { syncAudio() } }
    @Published var fadeInEnabled = false { didSet { syncAudio() } }
    @Published var fadeOutEnabled = false { didSet { syncAudio() } }
    @Published var fadeInDuration: Double = 1.0 {
        didSet {
            let v = Self.normalizeFade(fadeInDuration)
            if v != fadeInDuration { fadeInDuration = v }
            syncAudio()
        }
    }
    @Published var fadeOutDuration: Double = 1.0 {
        didSet {
            let v = Self.normalizeFade(fadeOutDuration)
            if v != fadeOutDuration { fadeOutDuration = v }
            syncAudio()
        }
    }
    @Published private(set) var effectSlots: [EffectSlot] = []
    @Published private(set) var availableEffects: [AVAudioUnitComponent] = []

    // Export / busy state
    @Published var exportQuality: ExportQuality = .high
    @Published private(set) var busyMessage: String?
    @Published private(set) var busyProgress: Double?
    @Published var alert: AlertInfo?

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var loadTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var exporter: VideoExporter?
    private var isSeeking = false
    private var chaseTime = CMTime.zero
    private var stopAtOutPoint = false

    init() {
        meter = MeterModel(state: meterState)
        player.actionAtItemEnd = .pause

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] time in
            self?.tick(time)
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = (status == .playing) }
            .store(in: &cancellables)

        installKeyMonitor()
        syncAudio()

        DispatchQueue.global(qos: .utility).async {
            let comps = PluginCatalog.effectComponents()
            DispatchQueue.main.async { self.availableEffects = comps }
        }
    }

    static func normalizeFade(_ v: Double) -> Double {
        ((v * 10).rounded() / 10).clamped(0.1, 5.0)
    }

    var rangeDuration: Double { max(0, outPoint - inPoint) }
    var isBusy: Bool { busyMessage != nil }

    // MARK: - Opening

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImporter.openableTypes
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "トリムする動画ファイルを選択してください"
        if panel.runModal() == .OK, let url = panel.url {
            open(url: url)
        }
    }

    func open(url: URL) {
        guard !isBusy || loadTask != nil else { return }
        loadTask?.cancel()
        loadTask = Task { @MainActor [weak self] in
            await self?.load(url)
        }
    }

    @MainActor
    private func load(_ url: URL) async {
        player.pause()
        busyMessage = "読み込んでいます…"
        busyProgress = nil
        defer {
            busyMessage = nil
            busyProgress = nil
            loadTask = nil
        }
        do {
            let prepared = try await MediaImporter.prepare(url: url, progress: { [weak self] fraction, message in
                DispatchQueue.main.async {
                    guard let self, self.loadTask != nil else { return }
                    self.busyMessage = message
                    self.busyProgress = fraction
                }
            }, registerProcess: { _ in })
            try Task.checkCancellation()

            let asset = AVURLAsset(url: prepared.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let duration = try await asset.load(.duration).seconds
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                throw ImportError.noVideo
            }
            let fps = Double(try await video.load(.nominalFrameRate))
            let natural = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let display = natural.applying(transform)
            let audioTrack = try await MediaImporter.primaryAudioTrack(asset)

            let item = AVPlayerItem(asset: asset)
            if let audioTrack {
                let ctx = TapContext(params: audioParams, chain: chain, meter: meterState, isPreview: true)
                item.audioMix = AudioTapFactory.makeAudioMix(track: audioTrack, context: ctx)
            }
            player.replaceCurrentItem(with: item)

            // Clean up a previous conversion
            if let old = self.asset as? AVURLAsset, old.url.path.hasPrefix(MediaImporter.tempDirectory.path), old.url != prepared.url {
                try? FileManager.default.removeItem(at: old.url)
            }

            self.asset = asset
            self.sourceURL = url
            self.duration = max(duration, 0)
            self.frameRate = fps > 0 ? fps : 30
            self.hasAudio = audioTrack != nil
            self.inPoint = 0
            self.outPoint = self.duration
            self.currentTime = 0
            var info = "\(Int(abs(display.width)))×\(Int(abs(display.height)))  ·  \(String(format: "%.2f", self.frameRate))fps  ·  \(TimeFormat.timecode(duration))"
            if !self.hasAudio { info += "  ·  音声なし" }
            if prepared.converted { info += "  ·  ffmpeg で変換済み" }
            self.mediaInfo = info
            syncAudio()
            chain.reset()
            seek(to: 0)   // forces the first frame to be drawn
            generateThumbnails(asset: asset, duration: duration)
        } catch is CancellationError {
            // ignore
        } catch {
            alert = AlertInfo(title: "読み込みエラー", message: error.localizedDescription)
        }
    }

    private func generateThumbnails(asset: AVAsset, duration: Double) {
        thumbnailTask?.cancel()
        thumbnails = []
        guard duration > 0 else { return }
        let count = 30
        thumbnailTask = Task { @MainActor [weak self] in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            let tolerance = CMTime(seconds: duration / Double(count) / 2, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            let times = (0..<count).map {
                CMTime(seconds: duration * (Double($0) + 0.5) / Double(count), preferredTimescale: 600)
            }
            var images: [NSImage] = []
            for await result in generator.images(for: times) {
                if Task.isCancelled { return }
                if let cg = try? result.image {
                    images.append(NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                    if images.count % 6 == 0 || images.count == count {
                        self?.thumbnails = images
                    }
                }
            }
            self?.thumbnails = images
        }
    }

    // MARK: - Transport

    private func tick(_ time: CMTime) {
        guard !isSeeking else { return }
        let t = time.seconds
        guard t.isFinite else { return }
        currentTime = t
        guard isPlaying else { return }
        if (loopRange || stopAtOutPoint) && t >= outPoint {
            if loopRange {
                seek(to: inPoint)
            } else {
                player.pause()
                stopAtOutPoint = false
                seek(to: outPoint)
            }
        }
    }

    func togglePlay() {
        guard asset != nil, !isBusy else { return }
        if isPlaying {
            player.pause()
            stopAtOutPoint = false
        } else {
            if currentTime >= duration - 0.02 || (loopRange && (currentTime < inPoint || currentTime >= outPoint)) {
                seek(to: inPoint)
            }
            player.play()
        }
    }

    func playRange() {
        guard asset != nil, !isBusy else { return }
        stopAtOutPoint = true
        seek(to: inPoint)
        chain.reset()
        player.play()
    }

    func seek(to seconds: Double) {
        guard asset != nil else { return }
        let t = seconds.clamped(0, duration)
        currentTime = t
        chaseTime = CMTime(seconds: t, preferredTimescale: 60_000)
        if !isSeeking { seekToChaseTime() }
    }

    private func seekToChaseTime() {
        isSeeking = true
        let target = chaseTime
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if CMTimeCompare(target, self.chaseTime) == 0 {
                    self.isSeeking = false
                } else {
                    self.seekToChaseTime()
                }
            }
        }
    }

    func stepFrames(_ count: Int) {
        guard let item = player.currentItem else { return }
        player.pause()
        item.step(byCount: count)
    }

    func jump(seconds: Double) {
        seek(to: currentTime + seconds)
    }

    // MARK: - Trim

    func setIn(_ value: Double) {
        guard value.isFinite, duration > 0 else { return }
        inPoint = value.clamped(0, max(0, outPoint - Self.minimumRange))
        syncAudio()
    }

    func setOut(_ value: Double) {
        guard value.isFinite, duration > 0 else { return }
        outPoint = value.clamped(min(duration, inPoint + Self.minimumRange), duration)
        syncAudio()
    }

    func setInToCurrent() { setIn(currentTime) }
    func setOutToCurrent() { setOut(currentTime) }

    func resetRange() {
        inPoint = 0
        outPoint = duration
        syncAudio()
    }

    var frameDuration: Double { 1 / max(frameRate, 1) }

    // MARK: - Audio

    private func syncAudio() {
        let gain = Decibel.toLinear(volumeDB)
        let fi = fadeInEnabled, fo = fadeOutEnabled
        let fid = fadeInDuration, fod = fadeOutDuration
        let s = inPoint
        let e = outPoint > inPoint ? outPoint : .greatestFiniteMagnitude
        audioParams.update {
            $0.gain = gain
            $0.fadeInEnabled = fi
            $0.fadeOutEnabled = fo
            $0.fadeInDuration = fid
            $0.fadeOutDuration = fod
            $0.trimStart = s
            $0.trimEnd = e
        }
    }

    func addEffect(_ component: AVAudioUnitComponent) {
        Task { @MainActor in
            do {
                let unit = try await PluginCatalog.instantiate(component)
                let slot = EffectSlot(name: component.name, manufacturer: component.manufacturerName, avUnit: unit)
                chain.add(slot)
                effectSlots = chain.allSlots
                PluginWindowManager.shared.show(slot: slot)
            } catch {
                alert = AlertInfo(title: "プラグインを読み込めません", message: "\(component.name)\n\(error.localizedDescription)")
            }
        }
    }

    func removeEffect(_ slot: EffectSlot) {
        PluginWindowManager.shared.close(slotID: slot.id)
        chain.remove(id: slot.id)
        effectSlots = chain.allSlots
    }

    func moveEffect(_ slot: EffectSlot, by delta: Int) {
        chain.move(id: slot.id, by: delta)
        effectSlots = chain.allSlots
    }

    // MARK: - Export

    func exportMovie() {
        guard let asset, !isBusy, rangeDuration > 0 else { return }
        player.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "movie"
        panel.nameFieldStringValue = "\(base)_trim\(exportQuality == .light ? "_light" : "").mp4"
        if let dir = sourceURL?.deletingLastPathComponent() {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let exporter = VideoExporter()
        self.exporter = exporter
        busyMessage = "MP4 を書き出しています（\(exportQuality.title)）…"
        busyProgress = 0
        let range = CMTimeRange(
            start: CMTime(seconds: inPoint, preferredTimescale: 60_000),
            end: CMTime(seconds: outPoint, preferredTimescale: 60_000))
        let quality = exportQuality

        Task { @MainActor in
            defer {
                self.exporter = nil
                self.busyMessage = nil
                self.busyProgress = nil
            }
            do {
                try await exporter.export(
                    asset: asset, timeRange: range, quality: quality,
                    audioParams: audioParams, chain: chain, to: url
                ) { [weak self] p in
                    DispatchQueue.main.async { self?.busyProgress = p }
                }
                alert = AlertInfo(title: "書き出しが完了しました", message: url.path, revealURL: url)
            } catch is CancellationError {
                // cancelled by user
            } catch {
                alert = AlertInfo(title: "書き出しエラー", message: error.localizedDescription)
            }
        }
    }

    func cancelBusy() {
        if let exporter {
            exporter.cancel()
        } else if let loadTask {
            loadTask.cancel()
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        // Leave keys alone while typing in a text field.
        if let responder = event.window?.firstResponder, responder is NSText { return false }
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        guard asset != nil, !isBusy else { return false }
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 49: togglePlay(); return true            // space
        case 123: shift ? jump(seconds: -1) : stepFrames(-1); return true   // left
        case 124: shift ? jump(seconds: 1) : stepFrames(1); return true     // right
        case 115: seek(to: inPoint); return true      // home
        case 119: seek(to: outPoint); return true     // end
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": setInToCurrent(); return true
        case "o": setOutToCurrent(); return true
        case "l": loopRange.toggle(); return true
        default: return false
        }
    }
}

// MARK: - Meter model (UI side)

final class MeterModel: ObservableObject {
    static let floorDB: Float = -70

    @Published private(set) var levels: [Float] = [-120, -120]
    @Published private(set) var holds: [Float] = [-120, -120]
    @Published var clipped = false

    private let state: MeterState
    private var holdTimes: [Date] = [.distantPast, .distantPast]
    private var timer: Timer?

    init(state: MeterState) {
        self.state = state
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let reading = state.readAndReset()
        let n = max(1, reading.channels)
        var newLevels = levels
        var newHolds = holds
        if newLevels.count != n {
            newLevels = Array(repeating: -120, count: n)
            newHolds = Array(repeating: -120, count: n)
            holdTimes = Array(repeating: .distantPast, count: n)
        }
        let now = Date()
        var anyChange = false
        for c in 0..<n {
            let peak = c < reading.peaks.count ? reading.peaks[c] : 0
            let db = Decibel.fromLinear(peak)
            let decayed = max(newLevels[c] - 1.2, -120)   // ~36 dB/s fall-off
            let level = max(db, decayed)
            if level != newLevels[c] { anyChange = true }
            newLevels[c] = level
            if db >= newHolds[c] {
                newHolds[c] = db
                holdTimes[c] = now
            } else if now.timeIntervalSince(holdTimes[c]) > 1.5 {
                newHolds[c] = max(newHolds[c] - 1.5, newLevels[c])
                anyChange = true
            }
            if peak >= 1.0 && !clipped { clipped = true }
        }
        if anyChange || levels.count != n {
            levels = newLevels
            holds = newHolds
        }
    }

    func resetClip() {
        clipped = false
        holds = holds.map { _ in -120 }
    }
}
