import Foundation
import AVFoundation
import MediaToolbox

// MARK: - Parameters shared between UI and audio threads

struct AudioParamsSnapshot {
    var gain: Float = 1
    var fadeInEnabled = false
    var fadeInDuration: Double = 1
    var fadeOutEnabled = false
    var fadeOutDuration: Double = 1
    var trimStart: Double = 0
    var trimEnd: Double = .greatestFiniteMagnitude
}

final class AudioParams {
    private let lock = UnfairLock()
    private var value = AudioParamsSnapshot()

    func update(_ body: (inout AudioParamsSnapshot) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }

    func read() -> AudioParamsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Level metering (written on the audio thread, read by the UI)

final class MeterState {
    static let maxChannels = 8

    private let lock = UnfairLock()
    private let peaks: UnsafeMutablePointer<Float>
    private let sumSquares: UnsafeMutablePointer<Double>
    private var frames = 0
    private var channels = 2

    init() {
        peaks = .allocate(capacity: Self.maxChannels)
        peaks.initialize(repeating: 0, count: Self.maxChannels)
        sumSquares = .allocate(capacity: Self.maxChannels)
        sumSquares.initialize(repeating: 0, count: Self.maxChannels)
    }

    deinit {
        peaks.deallocate()
        sumSquares.deallocate()
    }

    /// Called from the render thread. Never blocks.
    func submit(peaks newPeaks: UnsafePointer<Float>, sumSquares newSums: UnsafePointer<Double>, channels: Int, frames: Int) {
        guard lock.tryLock() else { return }
        self.channels = min(channels, Self.maxChannels)
        for c in 0..<self.channels {
            peaks[c] = max(peaks[c], newPeaks[c])
            sumSquares[c] += newSums[c]
        }
        self.frames += frames
        lock.unlock()
    }

    func readAndReset() -> (peaks: [Float], rms: [Float], channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        let n = channels
        var p = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n)
        for c in 0..<n {
            p[c] = peaks[c]
            r[c] = frames > 0 ? Float(sqrt(sumSquares[c] / Double(frames))) : 0
            peaks[c] = 0
            sumSquares[c] = 0
        }
        frames = 0
        return (p, r, n)
    }
}

// MARK: - Tap context

/// Per-tap state. Signal flow: source -> Audio Unit chain -> fader gain -> fades -> meter.
final class TapContext {
    let id = UUID()
    let params: AudioParams
    let chain: EffectChain
    let meter: MeterState?
    /// Preview plays outside the trim range without fades; export silences beyond it.
    let isPreview: Bool

    private var asbd = AudioStreamBasicDescription()
    private var maxFrames = 4096
    private var lastGain: Float = 1
    private var firstBuffer = true
    private var fallbackTime: Double = 0
    private let peakScratch: UnsafeMutablePointer<Float>
    private let sumScratch: UnsafeMutablePointer<Double>

    init(params: AudioParams, chain: EffectChain, meter: MeterState?, isPreview: Bool) {
        self.params = params
        self.chain = chain
        self.meter = meter
        self.isPreview = isPreview
        peakScratch = .allocate(capacity: MeterState.maxChannels)
        sumScratch = .allocate(capacity: MeterState.maxChannels)
    }

    deinit {
        peakScratch.deallocate()
        sumScratch.deallocate()
    }

    func prepare(maxFrames: Int, format: AudioStreamBasicDescription) {
        asbd = format
        if ProcessInfo.processInfo.environment["EMT_DEBUG"] != nil {
            FileHandle.standardError.write("tap prepare: sr=\(format.mSampleRate) ch=\(format.mChannelsPerFrame) flags=\(String(format: "%x", format.mFormatFlags)) bits=\(format.mBitsPerChannel) maxFrames=\(maxFrames)\n".data(using: .utf8)!)
        }
        self.maxFrames = max(maxFrames, 512)
        firstBuffer = true
        if isNonInterleavedFloat {
            chain.prepare(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame), maxFrames: self.maxFrames)
        }
    }

    private var isFloat32: Bool {
        asbd.mFormatID == kAudioFormatLinearPCM
            && (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && asbd.mBitsPerChannel == 32
    }

    private var isNonInterleavedFloat: Bool {
        isFloat32 && (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
    }

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int, timeRange: CMTimeRange) {
        guard frames > 0, isFloat32 else { return }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000

        // 1) Audio Unit insert chain
        if isNonInterleavedFloat {
            chain.render(abl, frames: frames, sampleRate: sampleRate, maxFrames: maxFrames, owner: id)
        }

        // 2) Fader + fades
        let p = params.read()
        let startTime: Double
        if timeRange.start.isNumeric {
            startTime = timeRange.start.seconds
        } else {
            startTime = fallbackTime
        }
        fallbackTime = startTime + Double(frames) / sampleRate

        let target = p.gain
        let from = firstBuffer ? target : lastGain
        firstBuffer = false
        lastGain = target
        let fadeActive = p.fadeInEnabled || p.fadeOutEnabled || !isPreview

        let channelCount = min(MeterState.maxChannels, Int(asbd.mChannelsPerFrame))
        for c in 0..<MeterState.maxChannels {
            peakScratch[c] = 0
            sumScratch[c] = 0
        }

        var channelBase = 0
        for bufferIndex in 0..<abl.count {
            guard let raw = abl[bufferIndex].mData else { continue }
            let data = raw.assumingMemoryBound(to: Float.self)
            let interleave = max(1, Int(abl[bufferIndex].mNumberChannels))
            let available = Int(abl[bufferIndex].mDataByteSize) / (4 * interleave)
            let n = min(frames, available)
            for i in 0..<n {
                var g = from + (target - from) * Float(i + 1) / Float(n)
                if fadeActive {
                    g *= Self.fadeGain(time: startTime + Double(i) / sampleRate, params: p, preview: isPreview)
                }
                for c in 0..<interleave {
                    let idx = i * interleave + c
                    let v = data[idx] * g
                    data[idx] = v
                    let ch = channelBase + c
                    if ch < MeterState.maxChannels {
                        let a = abs(v)
                        if a > peakScratch[ch] { peakScratch[ch] = a }
                        sumScratch[ch] += Double(v * v)
                    }
                }
            }
            channelBase += interleave
        }

        meter?.submit(peaks: peakScratch, sumSquares: sumScratch, channels: max(1, channelCount), frames: frames)
    }

    /// Equal-power style fade curve. Outside the trim range the preview plays unfaded,
    /// while export silences anything that strays beyond the range edges.
    @inline(__always)
    static func fadeGain(time t: Double, params p: AudioParamsSnapshot, preview: Bool) -> Float {
        if t < p.trimStart || t > p.trimEnd {
            return preview ? 1 : 0
        }
        var g = 1.0
        if p.fadeInEnabled, p.fadeInDuration > 0 {
            let x = (t - p.trimStart) / p.fadeInDuration
            if x < 1 { g *= sin(max(0, x) * .pi / 2) }
        }
        if p.fadeOutEnabled, p.fadeOutDuration > 0 {
            let x = (p.trimEnd - t) / p.fadeOutDuration
            if x < 1 { g *= sin(max(0, x) * .pi / 2) }
        }
        return Float(g)
    }
}

// MARK: - MTAudioProcessingTap factory

enum AudioTapFactory {
    static func makeTap(context: TapContext) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                let storage = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<TapContext>.fromOpaque(storage).release()
            },
            prepare: { tap, maxFrames, format in
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.prepare(maxFrames: Int(maxFrames), format: format.pointee)
            },
            unprepare: { _ in },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                var timeRange = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, &timeRange, numberFramesOut)
                guard status == noErr else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let ctx = Unmanaged<TapContext>.fromOpaque(storage).takeUnretainedValue()
                ctx.process(bufferListInOut, frames: Int(numberFramesOut.pointee), timeRange: timeRange)
            }
        )
        // The macOS 26 SDK returns the tap as a managed reference; older SDKs return Unmanaged.
        #if compiler(>=6.2)
        var tap: MTAudioProcessingTap?
        #else
        var tap: Unmanaged<MTAudioProcessingTap>?
        #endif
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
        guard status == noErr else {
            Unmanaged<TapContext>.fromOpaque(callbacks.clientInfo!).release()
            return nil
        }
        #if compiler(>=6.2)
        return tap
        #else
        return tap?.takeRetainedValue()
        #endif
    }

    static func makeAudioMix(track: AVAssetTrack, context: TapContext) -> AVAudioMix? {
        guard let tap = makeTap(context: context) else { return nil }
        let input = AVMutableAudioMixInputParameters(track: track)
        input.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [input]
        return mix
    }
}
