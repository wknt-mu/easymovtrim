import Foundation
import AVFoundation
import AudioToolbox

/// One inserted Audio Unit.
final class EffectSlot: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let manufacturer: String
    /// Keeps the instance alive and gives both the v2 handle (for rendering)
    /// and the AUAudioUnit (for UI, parameters and presets).
    let avUnit: AVAudioUnit

    var au: AUAudioUnit { avUnit.auAudioUnit }
    var unit: AudioUnit { avUnit.audioUnit }

    @Published var bypassed = false {
        didSet { renderBypassed = bypassed }
    }
    @Published var errorMessage: String?

    /// Plain copies read on the render thread.
    fileprivate var renderBypassed = false
    fileprivate var ready = false

    init(name: String, manufacturer: String, avUnit: AVAudioUnit) {
        self.name = name
        self.manufacturer = manufacturer
        self.avUnit = avUnit
    }
}

/// Input callback handed to every Audio Unit: supplies the current tap buffer.
private let chainInputCallback: AURenderCallback = { refCon, _, _, _, frameCount, ioData in
    let chain = Unmanaged<EffectChain>.fromOpaque(refCon).takeUnretainedValue()
    guard let ioData else { return kAudioUnitErr_InvalidParameter }
    return chain.provideInput(frames: Int(frameCount), into: UnsafeMutableAudioBufferListPointer(ioData))
}

/// Serial chain of Audio Unit effects, rendered in place on tap buffers.
final class EffectChain {
    private let lock = UnfairLock()
    private var slots: [EffectSlot] = []

    private var sampleRate: Double = 48_000
    private var channels = 2
    private var maxFrames: UInt32 = 4096

    private var scratch: UnsafeMutablePointer<Float>
    private var scratchCapacity: Int
    private let outputList: UnsafeMutableAudioBufferListPointer

    // Render-time state read by the input callback.
    private var currentInput: UnsafeMutableAudioBufferListPointer?
    private var chunkOffset = 0
    private var sampleTime: Double = 0

    /// When set, only the tap with this id may run the chain (used during export).
    var exclusiveOwner: UUID?

    init() {
        scratchCapacity = MeterState.maxChannels * 4096
        scratch = .allocate(capacity: scratchCapacity)
        scratch.initialize(repeating: 0, count: scratchCapacity)
        outputList = AudioBufferList.allocate(maximumBuffers: MeterState.maxChannels)
    }

    deinit {
        scratch.deallocate()
        outputList.unsafeMutablePointer.deallocate()
    }

    var allSlots: [EffectSlot] { lock.withLock { slots } }

    static func makeFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        if channels <= 2 {
            return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(max(1, channels)))
        }
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)) else {
            return nil
        }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }

    // MARK: Configuration

    func prepare(sampleRate: Double, channels: Int, maxFrames: Int) {
        lock.withLock {
            reconfigureIfNeededLocked(sampleRate: sampleRate, channels: channels, maxFrames: maxFrames)
        }
    }

    private func reconfigureIfNeededLocked(sampleRate: Double, channels: Int, maxFrames: Int) {
        let mf = UInt32(max(maxFrames, 4096))
        if sampleRate == self.sampleRate && channels == self.channels && mf <= self.maxFrames {
            return
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.maxFrames = max(mf, self.maxFrames)
        let needed = MeterState.maxChannels * Int(self.maxFrames)
        if needed > scratchCapacity {
            scratch.deallocate()
            scratch = .allocate(capacity: needed)
            scratch.initialize(repeating: 0, count: needed)
            scratchCapacity = needed
        }
        for slot in slots {
            configureLocked(slot)
        }
    }

    private func configureLocked(_ slot: EffectSlot) {
        let unit = slot.unit
        slot.ready = false
        AudioUnitUninitialize(unit)

        var message: String?
        if channels > MeterState.maxChannels {
            message = "チャンネル数が多すぎます"
        } else if let format = Self.makeFormat(sampleRate: sampleRate, channels: channels) {
            var asbd = format.streamDescription.pointee
            let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var frames = maxFrames
            var callback = AURenderCallbackStruct(
                inputProc: chainInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())

            var status = AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                              &frames, UInt32(MemoryLayout<UInt32>.size))
            if status == noErr {
                status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, asbdSize)
            }
            if status == noErr {
                status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, asbdSize)
            }
            if status == noErr {
                status = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                              &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            }
            if status == noErr {
                status = AudioUnitInitialize(unit)
            }
            if status == noErr {
                slot.ready = true
            } else {
                message = "\(channels)ch / \(Int(sampleRate))Hz に対応していません（バイパス中, \(status)）"
            }
        } else {
            message = "オーディオフォーマットを作成できません"
        }
        DispatchQueue.main.async { slot.errorMessage = message }
    }

    func add(_ slot: EffectSlot) {
        lock.withLock {
            configureLocked(slot)
            slots.append(slot)
        }
    }

    func remove(id: UUID) {
        lock.withLock {
            if let idx = slots.firstIndex(where: { $0.id == id }) {
                let slot = slots.remove(at: idx)
                AudioUnitUninitialize(slot.unit)
            }
        }
    }

    func move(id: UUID, by delta: Int) {
        lock.withLock {
            guard let idx = slots.firstIndex(where: { $0.id == id }) else { return }
            let newIdx = idx + delta
            guard newIdx >= 0, newIdx < slots.count else { return }
            slots.swapAt(idx, newIdx)
        }
    }

    /// Clears effect tails (reverb, delay) e.g. after a seek or before export.
    func reset() {
        lock.withLock {
            for slot in slots where slot.ready {
                AudioUnitReset(slot.unit, kAudioUnitScope_Global, 0)
            }
        }
    }

    // MARK: Rendering (audio thread)

    fileprivate func provideInput(frames: Int, into dst: UnsafeMutableAudioBufferListPointer) -> OSStatus {
        guard let input = currentInput else { return kAudioUnitErr_NoConnection }
        let bytes = frames * MemoryLayout<Float>.size
        let offsetBytes = chunkOffset * MemoryLayout<Float>.size
        for ch in 0..<min(dst.count, input.count) {
            guard let src = input[ch].mData?.advanced(by: offsetBytes) else { continue }
            if let d = dst[ch].mData {
                if d != src { memcpy(d, src, bytes) }
            } else {
                dst[ch].mData = src
            }
            dst[ch].mDataByteSize = UInt32(bytes)
        }
        return noErr
    }

    func render(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, sampleRate: Double, maxFrames: Int, owner: UUID) {
        if let o = exclusiveOwner, o != owner { return }
        guard lock.tryLock() else { return }
        defer { lock.unlock() }
        guard !slots.isEmpty else { return }

        if sampleRate != self.sampleRate || abl.count != channels || frames > Int(self.maxFrames) {
            reconfigureIfNeededLocked(sampleRate: sampleRate, channels: abl.count, maxFrames: max(maxFrames, frames))
        }
        guard abl.count == channels else { return }

        currentInput = abl
        let stride = Int(self.maxFrames)
        for slot in slots where slot.ready && !slot.renderBypassed {
            var offset = 0
            while offset < frames {
                let n = min(frames - offset, stride)
                chunkOffset = offset
                outputList.count = channels
                for ch in 0..<channels {
                    outputList[ch] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(n * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(scratch + ch * stride))
                }
                var flags = AudioUnitRenderActionFlags()
                var timestamp = AudioTimeStamp()
                timestamp.mSampleTime = sampleTime + Double(offset)
                timestamp.mFlags = .sampleTimeValid
                let status = AudioUnitRender(slot.unit, &flags, &timestamp, 0, UInt32(n), outputList.unsafeMutablePointer)
                if status == noErr {
                    let byteOffset = offset * MemoryLayout<Float>.size
                    for ch in 0..<channels {
                        guard let src = outputList[ch].mData, let dst = abl[ch].mData?.advanced(by: byteOffset) else { continue }
                        if src != dst {
                            memcpy(dst, src, n * MemoryLayout<Float>.size)
                        }
                    }
                }
                offset += n
            }
        }
        currentInput = nil
        sampleTime += Double(frames)
    }
}

// MARK: - Plugin discovery

enum PluginCatalog {
    static func effectComponents() -> [AVAudioUnitComponent] {
        let manager = AVAudioUnitComponentManager.shared()
        var result: [AVAudioUnitComponent] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let desc = AudioComponentDescription(
                componentType: type, componentSubType: 0, componentManufacturer: 0,
                componentFlags: 0, componentFlagsMask: 0)
            result.append(contentsOf: manager.components(matching: desc))
        }
        return result.sorted {
            if $0.manufacturerName != $1.manufacturerName {
                return $0.manufacturerName.localizedCaseInsensitiveCompare($1.manufacturerName) == .orderedAscending
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func instantiate(_ component: AVAudioUnitComponent) async throws -> AVAudioUnit {
        try await withCheckedThrowingContinuation { cont in
            AVAudioUnit.instantiate(with: component.audioComponentDescription, options: []) { unit, error in
                if let unit {
                    cont.resume(returning: unit)
                } else {
                    cont.resume(throwing: error ?? NSError(domain: "EasyMovTrim", code: -1, userInfo: [NSLocalizedDescriptionKey: "プラグインを読み込めませんでした"]))
                }
            }
        }
    }
}
