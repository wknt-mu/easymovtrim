import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                header
                preview
                TransportBar()
                TimelineStrip()
                HStack(alignment: .top, spacing: 12) {
                    TrimControls()
                    ExportBox()
                        .frame(width: 330)
                }
            }
            .padding(16)

            Divider()

            AudioPanel()
                .frame(width: 300)
                .disabled(model.isBusy)
        }
        .overlay { busyOverlay }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { model.open(url: url) }
                }
            }
            return true
        }
        .alert(item: $model.alert) { info in
            if let url = info.revealURL {
                return Alert(
                    title: Text(info.title), message: Text(info.message),
                    primaryButton: .default(Text("Finder で表示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    },
                    secondaryButton: .cancel(Text("閉じる")))
            }
            return Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                model.showOpenPanel()
            } label: {
                Label("開く…", systemImage: "folder")
            }
            .disabled(model.isBusy)
            if let url = model.sourceURL {
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    Text(model.mediaInfo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("動画ファイルを開いてください").foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var preview: some View {
        ZStack {
            Color.black
            if model.asset != nil {
                PlayerSurface(player: model.player)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "film.stack")
                        .font(.system(size: 52, weight: .light))
                    Text("ここに動画ファイルをドロップ")
                        .font(.title3)
                    Text("または ⌘O で開く  ·  MP4 / MOV / MKV / WebM / AVI / FLV / WMV / MTS など")
                        .font(.caption)
                    Button("ファイルを開く…") { model.showOpenPanel() }
                        .padding(.top, 4)
                }
                .foregroundStyle(.white.opacity(0.75))
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 280)
        .onTapGesture { model.togglePlay() }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if let message = model.busyMessage {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea()
                VStack(spacing: 14) {
                    Text(message).font(.headline)
                    if let p = model.busyProgress {
                        ProgressView(value: p)
                            .frame(width: 320)
                        Text("\(Int(p * 100))%")
                            .font(.system(.body, design: .monospaced))
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Button("キャンセル") { model.cancelBusy() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}

struct ExportBox: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $model.exportQuality) {
                    ForEach(ExportQuality.allCases) { q in
                        Text(q.title).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.exportQuality.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    model.exportMovie()
                } label: {
                    Label("MP4 を書き出す…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
            }
            .padding(6)
        } label: {
            Label("エクスポート", systemImage: "film")
        }
        .disabled(model.asset == nil || model.isBusy)
    }
}
