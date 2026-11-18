import SwiftUI
import AVFoundation

struct AudioPanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("オーディオ", systemImage: "speaker.wave.2.fill")
                    .font(.headline)

                // Meter + fader
                HStack(alignment: .top, spacing: 10) {
                    LevelMeterView(meter: model.meter)
                    VolumeFader(db: $model.volumeDB)
                        .frame(width: 70)
                }
                .frame(height: 260)
                .frame(maxWidth: .infinity)

                HStack {
                    Text("音量")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(volumeText)
                        .font(.system(.body, design: .monospaced))
                    Button("0 dB") { model.volumeDB = 0 }
                        .controlSize(.small)
                }

                Divider()

                FadeControl(title: "フェードイン", systemImage: "speaker.wave.1",
                            enabled: $model.fadeInEnabled, duration: $model.fadeInDuration)
                FadeControl(title: "フェードアウト", systemImage: "speaker.wave.1",
                            enabled: $model.fadeOutEnabled, duration: $model.fadeOutDuration)

                Divider()

                PluginRack()
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var volumeText: String {
        model.volumeDB <= Decibel.silenceDB ? "-∞ dB" : String(format: "%+.1f dB", model.volumeDB)
    }
}

// MARK: - Fades

struct FadeControl: View {
    let title: String
    let systemImage: String
    @Binding var enabled: Bool
    @Binding var duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $enabled) {
                Text(title).fontWeight(.medium)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            HStack(spacing: 6) {
                Slider(value: $duration, in: 0.1...5.0, step: 0.1)
                TextField("", value: $duration, format: .number.precision(.fractionLength(1)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48)
                Text("秒").foregroundStyle(.secondary)
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
    }
}

// MARK: - Level meter

struct LevelMeterView: View {
    @ObservedObject var meter: MeterModel

    static let minDB: Float = -60
    static let maxDB: Float = 6
    static let scaleMarks: [Float] = [6, 0, -6, -12, -20, -30, -40, -60]

    static func fraction(_ db: Float) -> CGFloat {
        CGFloat((db.clamped(minDB, maxDB) - minDB) / (maxDB - minDB))
    }

    var body: some View {
        VStack(spacing: 4) {
            // Clip indicator
            Button {
                meter.resetClip()
            } label: {
                RoundedRectangle(cornerRadius: 2)
                    .fill(meter.clipped ? Color.red : Color.red.opacity(0.18))
                    .frame(width: CGFloat(meter.levels.count) * 13, height: 8)
            }
            .buttonStyle(.plain)
            .help("クリップ表示（クリックでリセット）")

            HStack(alignment: .top, spacing: 4) {
                HStack(spacing: 3) {
                    ForEach(0..<meter.levels.count, id: \.self) { c in
                        MeterBar(level: meter.levels[c], hold: meter.holds[c])
                            .frame(width: 10)
                    }
                }
                MeterScale()
                    .frame(width: 24)
            }

            HStack(spacing: 3) {
                ForEach(0..<meter.levels.count, id: \.self) { c in
                    Text(channelLabel(c, of: meter.levels.count))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                Spacer().frame(width: 28)
            }
            Text(peakText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(meter.clipped ? .red : .secondary)
        }
    }

    private var peakText: String {
        let maxHold = meter.holds.max() ?? -120
        return maxHold <= -100 ? "-∞" : String(format: "%.1f", maxHold)
    }

    private func channelLabel(_ c: Int, of n: Int) -> String {
        if n == 1 { return "M" }
        if n == 2 { return c == 0 ? "L" : "R" }
        return "\(c + 1)"
    }
}

private struct MeterBar: View {
    let level: Float
    let hold: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black.opacity(0.75))
                LinearGradient(
                    stops: [
                        .init(color: .green, location: 0),
                        .init(color: .green, location: 0.70),
                        .init(color: .yellow, location: 0.76),
                        .init(color: .orange, location: 0.86),
                        .init(color: .red, location: 0.91),
                    ],
                    startPoint: .bottom, endPoint: .top)
                .mask(alignment: .bottom) {
                    Rectangle().frame(height: h * LevelMeterView.fraction(level))
                }
                if hold > LevelMeterView.minDB {
                    Rectangle()
                        .fill(hold >= 0 ? Color.red : Color.white.opacity(0.9))
                        .frame(height: 2)
                        .offset(y: -h * LevelMeterView.fraction(hold) + 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

private struct MeterScale: View {
    var body: some View {
        GeometryReader { geo in
            ForEach(LevelMeterView.scaleMarks, id: \.self) { db in
                Text(db > 0 ? "+\(Int(db))" : "\(Int(db))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .position(x: 12, y: geo.size.height * (1 - LevelMeterView.fraction(db)))
            }
        }
    }
}

// MARK: - Fader

enum FaderLaw {
    static let points: [(db: Double, pos: Double)] = [
        (-60, 0.0), (-40, 0.12), (-30, 0.22), (-20, 0.36), (-10, 0.55), (-5, 0.66), (0, 0.78), (6, 0.89), (12, 1.0),
    ]

    static func position(_ db: Double) -> Double {
        if db <= points[0].db { return 0 }
        for i in 1..<points.count where db <= points[i].db {
            let a = points[i - 1], b = points[i]
            return a.pos + (db - a.db) / (b.db - a.db) * (b.pos - a.pos)
        }
        return 1
    }

    static func db(_ pos: Double) -> Double {
        if pos <= 0 { return points[0].db }
        for i in 1..<points.count where pos <= points[i].pos {
            let a = points[i - 1], b = points[i]
            return a.db + (pos - a.pos) / (b.pos - a.pos) * (b.db - a.db)
        }
        return points.last!.db
    }
}

struct VolumeFader: View {
    @Binding var db: Double
    @State private var dragStart: Double?

    private let knobHeight: CGFloat = 30
    private let marks: [Double] = [12, 6, 0, -5, -10, -20, -30, -40, -60]

    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height - knobHeight
            let centerX = geo.size.width / 2 + 10
            let y = { (d: Double) -> CGFloat in (1 - CGFloat(FaderLaw.position(d))) * travel + knobHeight / 2 }

            ZStack {
                // Scale
                ForEach(marks, id: \.self) { m in
                    Text(m <= -60 ? "-∞" : (m > 0 ? "+\(Int(m))" : "\(Int(m))"))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(m == 0 ? .primary : .secondary)
                        .position(x: 10, y: y(m))
                    Rectangle()
                        .fill(Color.secondary.opacity(m == 0 ? 0.9 : 0.4))
                        .frame(width: m == 0 ? 30 : 22, height: 1)
                        .position(x: centerX, y: y(m))
                }
                // Groove
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.black.opacity(0.7))
                    .frame(width: 5, height: travel)
                    .position(x: centerX, y: geo.size.height / 2)
                // Knob
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.black.opacity(0.8)).frame(height: 2))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4), lineWidth: 0.5))
                    .shadow(radius: 1.5, y: 1)
                    .frame(width: 36, height: knobHeight)
                    .position(x: centerX, y: y(db))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = FaderLaw.position(db) }
                        let fine = NSEvent.modifierFlags.contains(.shift) ? 0.2 : 1.0
                        let pos = (dragStart! - Double(value.translation.height / max(travel, 1)) * fine).clamped(0, 1)
                        db = (FaderLaw.db(pos) * 10).rounded() / 10
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { db = 0 })
            .help("ドラッグで音量調整（Shift で微調整、ダブルクリックで 0 dB）")
        }
    }
}

// MARK: - Plugin rack

struct PluginRack: View {
    @EnvironmentObject var model: AppModel

    private var grouped: [(String, [AVAudioUnitComponent])] {
        Dictionary(grouping: model.availableEffects, by: { $0.manufacturerName })
            .map { ($0.key, $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("プラグイン (Audio Unit)", systemImage: "puzzlepiece.extension")
                    .fontWeight(.medium)
                Spacer()
                Menu {
                    if model.availableEffects.isEmpty {
                        Text("Audio Unit エフェクトが見つかりません")
                    }
                    ForEach(grouped, id: \.0) { manufacturer, comps in
                        Menu(manufacturer) {
                            ForEach(comps, id: \.self) { comp in
                                Button(comp.name) { model.addEffect(comp) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("プラグインを挿入")
            }

            if model.effectSlots.isEmpty {
                Text("「+」から Audio Unit エフェクトを挿入できます。上から順に処理されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(model.effectSlots.enumerated()), id: \.element.id) { index, slot in
                        EffectRow(slot: slot, index: index, count: model.effectSlots.count)
                    }
                }
            }
            Text("信号の流れ: プラグイン → フェーダー → フェード → メーター")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct EffectRow: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var slot: EffectSlot
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(get: { !slot.bypassed }, set: { slot.bypassed = !$0 }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("オン / バイパス")
            VStack(alignment: .leading, spacing: 1) {
                Text(slot.name).lineLimit(1)
                    .foregroundStyle(slot.bypassed ? .secondary : .primary)
                if let err = slot.errorMessage {
                    Text(err).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                } else {
                    Text(slot.manufacturer).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            Button { PluginWindowManager.shared.show(slot: slot) } label: { Image(systemName: "slider.horizontal.3") }
                .help("プラグイン画面を開く")
            Button { model.moveEffect(slot, by: -1) } label: { Image(systemName: "chevron.up") }
                .disabled(index == 0)
            Button { model.moveEffect(slot, by: 1) } label: { Image(systemName: "chevron.down") }
                .disabled(index == count - 1)
            Button { model.removeEffect(slot) } label: { Image(systemName: "trash") }
                .help("削除")
        }
        .buttonStyle(.borderless)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
