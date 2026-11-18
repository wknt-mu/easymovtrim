import Foundation
import AVFoundation
import CoreMedia

enum ExportQuality: String, CaseIterable, Identifiable {
    case light
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "軽量"
        case .high: return "高品質"
        }
    }

    var detail: String {
        switch self {
        case .light: return "H.264・最大720p・低ビットレート / AAC 128kbps"
        case .high: return "H.264・元の解像度・高ビットレート / AAC 256kbps"
        }
    }

    var audioBitrate: Int { self == .light ? 128_000 : 256_000 }

    func targetSize(natural: CGSize) -> (width: Int, height: Int) {
        var w = abs(natural.width)
        var h = abs(natural.height)
        if w < 2 || h < 2 { w = 1280; h = 720 }
        if self == .light {
            let scale = min(1, 1280 / max(w, h), 720 / min(w, h))
            w *= scale
            h *= scale
        }
        return (Int((w / 2).rounded()) * 2, Int((h / 2).rounded()) * 2)
    }

    func videoBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixelsPerSecond = Double(width * height) * min(max(fps, 1), 120)
        switch self {
        case .light: return Int((pixelsPerSecond * 0.08).clamped(800_000, 4_000_000))
        case .high: return Int((pixelsPerSecond * 0.2).clamped(6_000_000, 60_000_000))
        }
    }
}

enum ExportError: LocalizedError {
    case noVideo
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "映像トラックがありません。"
        case .failed(let msg): return "書き出しに失敗しました: \(msg)"
        }
    }
}

/// Trims, re-encodes and writes an MP4, running the audio through the same tap as preview.
final class VideoExporter {
    private let stateLock = UnfairLock()
    private var _cancelled = false
    var isCancelled: Bool { stateLock.withLock { _cancelled } }

    func cancel() { stateLock.withLock { _cancelled = true } }

    func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        quality: ExportQuality,
        audioParams: AudioParams,
        chain: EffectChain,
        to outputURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideo
        }
        let audioTrack = try await MediaImporter.primaryAudioTrack(asset)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        var fps = Double(try await videoTrack.load(.nominalFrameRate))
        if fps <= 0 { fps = 30 }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        // Video
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ExportError.failed("映像を読み込めません") }
        reader.add(videoOutput)

        let size = quality.targetSize(natural: naturalSize)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitrate(width: size.width, height: size.height, fps: fps),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else { throw ExportError.failed("映像エンコーダーを準備できません") }
        writer.add(videoInput)

        // Audio
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        var tapContext: TapContext?
        if let audioTrack {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

            let ctx = TapContext(params: audioParams, chain: chain, meter: nil, isPreview: false)
            tapContext = ctx
            let output = AVAssetReaderAudioMixOutput(audioTracks: [audioTrack], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVChannelLayoutKey: layoutData,
            ])
            output.audioMix = AudioTapFactory.makeAudioMix(track: audioTrack, context: ctx)
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVChannelLayoutKey: layoutData,
                    AVEncoderBitRateKey: quality.audioBitrate,
                ])
                input.expectsMediaDataInRealTime = false
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }
        }

        chain.exclusiveOwner = tapContext?.id
        chain.reset()
        defer {
            chain.exclusiveOwner = nil
            chain.reset()
        }

        guard writer.startWriting() else {
            throw ExportError.failed(writer.error?.localizedDescription ?? "writer")
        }
        guard reader.startReading() else {
            writer.cancelWriting()
            throw ExportError.failed(reader.error?.localizedDescription ?? "reader")
        }
        writer.startSession(atSourceTime: .zero)

        let start = timeRange.start
        let total = max(timeRange.duration.seconds, 0.001)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let group = DispatchGroup()

            // Video pump
            group.enter()
            let videoQueue = DispatchQueue(label: "export.video")
            var videoDone = false
            var preroll: CMSampleBuffer?
            videoInput.requestMediaDataWhenReady(on: videoQueue) {
                while videoInput.isReadyForMoreMediaData && !videoDone {
                    if self.isCancelled || writer.status == .failed {
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        if pts < start {
                            // Keep the frame visible at the in-point in case no frame lands exactly on it.
                            preroll = sample
                            continue
                        }
                        if let p = preroll {
                            preroll = nil
                            if pts > start, let r = Self.retimed(p, shift: start, forcePTS: .zero) {
                                videoInput.append(r)
                            }
                        }
                        if let r = Self.retimed(sample, shift: start, forcePTS: nil) {
                            if !videoInput.append(r) {
                                videoDone = true
                                videoInput.markAsFinished()
                                group.leave()
                                return
                            }
                        }
                        progress(((pts - start).seconds / total).clamped(0, 1))
                    } else {
                        if let p = preroll, let r = Self.retimed(p, shift: start, forcePTS: .zero) {
                            preroll = nil
                            videoInput.append(r)
                        }
                        videoDone = true
                        videoInput.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }

            // Audio pump
            if let audioInput, let audioOutput {
                group.enter()
                let audioQueue = DispatchQueue(label: "export.audio")
                var audioDone = false
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData && !audioDone {
                        if self.isCancelled || writer.status == .failed {
                            audioDone = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                        if let sample = audioOutput.copyNextSampleBuffer() {
                            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                            let dur = CMSampleBufferGetDuration(sample)
                            if dur.isNumeric, pts + dur <= start { continue }
                            if let r = Self.retimed(sample, shift: start, forcePTS: nil) {
                                if !audioInput.append(r) {
                                    audioDone = true
                                    audioInput.markAsFinished()
                                    group.leave()
                                    return
                                }
                            }
                        } else {
                            audioDone = true
                            audioInput.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if self.isCancelled {
                    reader.cancelReading()
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: outputURL)
                    cont.resume(throwing: CancellationError())
                    return
                }
                if reader.status == .failed {
                    writer.cancelWriting()
                    cont.resume(throwing: ExportError.failed(reader.error?.localizedDescription ?? "読み込みエラー"))
                    return
                }
                if writer.status == .failed {
                    reader.cancelReading()
                    cont.resume(throwing: ExportError.failed(writer.error?.localizedDescription ?? "書き込みエラー"))
                    return
                }
                writer.endSession(atSourceTime: timeRange.duration)
                writer.finishWriting {
                    if writer.status == .completed {
                        progress(1)
                        cont.resume()
                    } else {
                        cont.resume(throwing: ExportError.failed(writer.error?.localizedDescription ?? "書き込みエラー"))
                    }
                }
            }
        }
    }

    /// Shifts sample timestamps so the trim in-point becomes zero.
    static func retimed(_ sample: CMSampleBuffer, shift: CMTime, forcePTS: CMTime?) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
        for i in 0..<count {
            if let forced = forcePTS {
                infos[i].presentationTimeStamp = forced
                infos[i].decodeTimeStamp = .invalid
            } else {
                infos[i].presentationTimeStamp = infos[i].presentationTimeStamp - shift
                if infos[i].decodeTimeStamp.isValid {
                    infos[i].decodeTimeStamp = infos[i].decodeTimeStamp - shift
                }
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &infos, sampleBufferOut: &out)
        return out
    }
}
