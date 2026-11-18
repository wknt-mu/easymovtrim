import SwiftUI
import AVKit

// MARK: - Video surface

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Text(TimeFormat.timecode(model.currentTime))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .frame(width: 120, alignment: .leading)

            Spacer()

            Group {
                iconButton("arrow.left.to.line", help: "IN 点へ移動 (Home)") { model.seek(to: model.inPoint) }
                iconButton("chevron.left", help: "1 フレーム戻る (←)") { model.stepFrames(-1) }
                Button(action: model.togglePlay) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 44, height: 30)
                }
                .help("再生 / 一時停止 (Space)")
                iconButton("chevron.right", help: "1 フレーム進む (→)") { model.stepFrames(1) }
                iconButton("arrow.right.to.line", help: "OUT 点へ移動 (End)") { model.seek(to: model.outPoint) }
            }

            Divider().frame(height: 20)

            Button {
                model.playRange()
            } label: {
                Label("範囲を再生", systemImage: "play.rectangle")
            }
            .help("IN 点から OUT 点までを再生します")

            Toggle(isOn: $model.loopRange) {
                Label("ループ", systemImage: "repeat")
            }
            .toggleStyle(.button)
            .help("トリム範囲をループ再生 (L)")

            Spacer()

            Text(TimeFormat.timecode(model.duration))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
        }
        .disabled(model.asset == nil)
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

// MARK: - Timeline with thumbnails and trim handles

struct TimelineStrip: View {
    @EnvironmentObject var model: AppModel
    @State private var dragTarget: DragTarget?

    private enum DragTarget { case inHandle, outHandle, playhead }

    private let rulerHeight: CGFloat = 18
    private let stripHeight: CGFloat = 58
    private let handleWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let xIn = x(model.inPoint, width)
            let xOut = x(model.outPoint, width)
            let xNow = x(model.currentTime, width)

            ZStack(alignment: .topLeading) {
                TimeRuler(duration: model.duration)
                    .frame(width: width, height: rulerHeight)

                // Thumbnails
                ThumbnailStrip(images: model.thumbnails, height: stripHeight)
                    .frame(width: width, height: stripHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(y: rulerHeight)

                // Dim outside the range
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, xIn), height: stripHeight)
                    .offset(y: rulerHeight)
                Rectangle().fill(Color.black.opacity(0.62))
                    .frame(width: max(0, width - xOut), height: stripHeight)
                    .offset(x: xOut, y: rulerHeight)

                // Range frame
                Rectangle()
                    .strokeBorder(Color.yellow, lineWidth: 3)
                    .frame(width: max(handleWidth * 2, xOut - xIn), height: stripHeight)
                    .offset(x: xIn, y: rulerHeight)

                handle(left: true)
                    .offset(x: xIn, y: rulerHeight)
                handle(left: false)
                    .offset(x: xOut - handleWidth, y: rulerHeight)

                // Playhead
                ZStack(alignment: .top) {
                    Rectangle().fill(Color.red).frame(width: 2, height: rulerHeight + stripHeight + 4)
                    Triangle().fill(Color.red).frame(width: 11, height: 8)
                }
                .frame(width: 11)
                .offset(x: xNow - 5.5)
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard model.duration > 0 else { return }
                        if dragTarget == nil {
                            dragTarget = pickTarget(at: value.startLocation, width: width, xIn: xIn, xOut: xOut)
                        }
                        let t = time(at: value.location.x, width)
                        switch dragTarget {
                        case .inHandle:
                            model.setIn(t)
                            model.seek(to: model.inPoint)
                        case .outHandle:
                            model.setOut(t)
                            model.seek(to: model.outPoint)
                        default:
                            model.seek(to: t)
                        }
                    }
                    .onEnded { _ in dragTarget = nil }
            )
        }
        .frame(height: rulerHeight + stripHeight + 4)
        .disabled(model.asset == nil)
    }

    private func handle(left: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: left ? 4 : 0, bottomLeadingRadius: left ? 4 : 0,
            bottomTrailingRadius: left ? 0 : 4, topTrailingRadius: left ? 0 : 4)
            .fill(Color.yellow)
            .frame(width: handleWidth, height: stripHeight)
            .overlay(
                Image(systemName: left ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.7))
            )
            .allowsHitTesting(false)
    }

    private func pickTarget(at point: CGPoint, width: CGFloat, xIn: CGFloat, xOut: CGFloat) -> DragTarget {
        guard point.y >= rulerHeight else { return .playhead }
        let dIn = abs(point.x - (xIn + handleWidth / 2))
        let dOut = abs(point.x - (xOut - handleWidth / 2))
        let grab: CGFloat = 12
        if dIn <= grab || dOut <= grab {
            return dIn <= dOut ? .inHandle : .outHandle
        }
        return .playhead
    }

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(t / model.duration) * width
    }

    private func time(at x: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return (Double(x / width) * model.duration).clamped(0, model.duration)
    }
}

/// Shows frames at their own aspect ratio, sampling as many as fit the width.
struct ThumbnailStrip: View {
    let images: [NSImage]
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let picks = sample(width: geo.size.width)
            let cell = geo.size.width / CGFloat(max(picks.count, 1))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.85))
                HStack(spacing: 0) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: cell, height: height)
                            .clipped()
                    }
                }
            }
        }
    }

    private func sample(width: CGFloat) -> [NSImage] {
        guard let first = images.first else { return [] }
        let imageHeight: CGFloat = max(first.size.height, 1)
        let aspect: CGFloat = max(0.3, first.size.width / imageHeight)
        let cellWidth: CGFloat = height * aspect
        let visible: Int = max(1, Int((width / cellWidth).rounded(.up)))
        let count: Int = images.count
        var result: [NSImage] = []
        result.reserveCapacity(visible)
        for i in 0..<visible {
            let position: Double = (Double(i) + 0.5) / Double(visible)
            let idx: Int = min(count - 1, Int(position * Double(count)))
            result.append(images[idx])
        }
        return result
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct TimeRuler: View {
    let duration: Double

    var body: some View {
        Canvas { ctx, size in
            guard duration > 0, size.width > 0 else { return }
            let pps = size.width / duration
            let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let major = steps.first { $0 * pps >= 70 } ?? 7200
            let minor = major / 5
            var i = 0
            while true {
                let t = Double(i) * minor
                if t > duration + 0.0001 { break }
                let x = t * pps
                let isMajor = i % 5 == 0
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - (isMajor ? 8 : 4)))
                path.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.9 : 0.5)), lineWidth: 1)
                if isMajor {
                    let label = TimeFormat.short(t, fractional: major < 1)
                    ctx.draw(Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: x + 3, y: 0), anchor: .topLeading)
                }
                i += 1
            }
        }
    }
}

// MARK: - Numeric trim controls

struct TrimControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("開始").foregroundStyle(.secondary)
                    SecondsField(
                        value: Binding(get: { model.inPoint }, set: { model.setIn($0) }),
                        step: model.frameDuration)
                    Text(TimeFormat.timecode(model.inPoint))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("現在位置を開始に (I)") { model.setInToCurrent() }
                }
                GridRow {
                    Text("終了").foregroundStyle(.secondary)
                    SecondsField(
                        value: Binding(get: { model.outPoint }, set: { model.setOut($0) }),
                        step: model.frameDuration)
                    Text(TimeFormat.timecode(model.outPoint))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("現在位置を終了に (O)") { model.setOutToCurrent() }
                }
                GridRow {
                    Text("長さ").foregroundStyle(.secondary)
                    Text(String(format: "%.3f 秒", model.rangeDuration))
                        .font(.system(.body, design: .monospaced))
                    Text(TimeFormat.timecode(model.rangeDuration))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("範囲をリセット") { model.resetRange() }
                }
            }
            .padding(6)
        } label: {
            Label("トリム範囲（秒）", systemImage: "scissors")
        }
        .disabled(model.asset == nil)
    }
}

struct SecondsField: View {
    @Binding var value: Double
    var step: Double

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number.precision(.fractionLength(3)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(.body, design: .monospaced))
                .frame(width: 96)
            Stepper("", onIncrement: { value += step }, onDecrement: { value -= step })
                .labelsHidden()
                .help("1 フレームずつ調整")
            Text("秒").foregroundStyle(.secondary)
        }
    }
}
