import Foundation
import os

/// Lightweight lock usable from audio render threads (supports try-lock).
final class UnfairLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>

    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }

    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }

    @inline(__always) func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(pointer) }
    @inline(__always) func tryLock() -> Bool { os_unfair_lock_trylock(pointer) }

    @inline(__always) func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum TimeFormat {
    /// 00:01:23.456
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--:--.---" }
        let t = max(0, seconds)
        let h = Int(t / 3600)
        let m = Int(t.truncatingRemainder(dividingBy: 3600) / 60)
        let s = t.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s)
    }

    /// Short label for rulers: 1:05 / 1:05.5
    static func short(_ seconds: Double, fractional: Bool) -> String {
        let t = max(0, seconds)
        let m = Int(t / 60)
        let s = t.truncatingRemainder(dividingBy: 60)
        if fractional {
            return String(format: "%d:%04.1f", m, s)
        }
        return String(format: "%d:%02d", m, Int(s.rounded(.down)))
    }
}

enum Decibel {
    static let silenceDB: Double = -60

    static func toLinear(_ db: Double) -> Float {
        db <= silenceDB ? 0 : Float(pow(10, db / 20))
    }

    static func fromLinear(_ value: Float) -> Float {
        value <= 0.000_001 ? -120 : 20 * log10(value)
    }
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self {
        min(max(self, lower), upper)
    }
}
