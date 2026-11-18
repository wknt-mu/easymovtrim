# EasyMovTrim

macOS 用の動画トリムアプリです（SwiftUI + AVFoundation、単体で動作）。

## 機能

| 機能 | 内容 |
|---|---|
| 読み込み | MP4 / MOV / M4V はそのまま開きます。MKV / WebM / AVI / FLV / WMV / MTS / MPG / VOB / OGV / 3GP などは ffmpeg で自動変換して開きます（可能なら再エンコードなしで中身を詰め替え、無理なら再エンコード。インターレースは自動で解除） |
| トリム範囲 | タイムラインの黄色いハンドルをドラッグするか、開始・終了を秒数で入力（▲▼ で 1 フレームずつ） |
| プレビュー | 動画の最初から最後までシーク・再生可能。範囲再生 / ループ再生 / コマ送り |
| 書き出し | MP4（H.264 + AAC）で新規ファイルに保存。**軽量**: 最大 720p・約 1〜4 Mbps・AAC 128kbps / **高品質**: 元の解像度・約 6〜60 Mbps・AAC 256kbps |
| フェード | フェードイン・フェードアウトを個別にオン/オフ、0.1〜5.0 秒（0.1 秒刻み） |
| メーター | L/R ピークメーター（ピークホールド・クリップ表示付き） |
| フェーダー | -∞〜+12 dB。Shift+ドラッグで微調整、ダブルクリックで 0 dB |
| プラグイン | Audio Unit（AUv2 / AUv3）エフェクトを複数挿入可能。並べ替え・バイパス・プラグイン画面の表示（専用画面がない場合はパラメーター一覧を表示） |

音声の処理順は **プラグイン → フェーダー → フェード → メーター** です。プレビューと書き出しで同じ処理を使うため、聴いた音のまま書き出されます。

### キーボード操作

| キー | 動作 |
|---|---|
| Space | 再生 / 一時停止 |
| ← / → | 1 フレーム戻る / 進む（Shift で 1 秒） |
| I / O | 現在位置を開始点 / 終了点に |
| Home / End | 開始点 / 終了点へ移動 |
| L | ループ再生 切り替え |
| ⌘O / ⌘E | 開く / 書き出す |

## ビルド

Xcode（コマンドラインツール）が入った macOS 14 以降で:

```bash
./build.sh
```

`build/EasyMovTrim.app` ができます。Intel Mac でも動くユニバーサル版は `UNIVERSAL=1 ./build.sh`。

### ffmpeg について

MP4/MOV 以外の形式を開くときに ffmpeg を使います。探す順番は次のとおりです。

1. アプリ内 `EasyMovTrim.app/Contents/Resources/bin/ffmpeg`
2. `/opt/homebrew/bin`, `/usr/local/bin` など

他の Mac にアプリだけを配って使う場合は、静的リンク版の `ffmpeg` と `ffprobe` を `vendor/` に置いてからビルドすると、アプリ内に同梱されます（Homebrew 版は外部ライブラリに依存するため、同梱しても他の Mac では動きません）。

## コマンドラインでの書き出し

```bash
build/EasyMovTrim.app/Contents/MacOS/EasyMovTrim --export in.mkv out.mp4 \
  --in 2.5 --out 7.5 --quality light --fadein 1 --fadeout 2 --volume -6 --plugin "AUDelay"
build/EasyMovTrim.app/Contents/MacOS/EasyMovTrim --list-plugins
```

## 構成

- `AudioProcessing.swift` — 音声タップ（音量・フェード・メーター）
- `EffectChain.swift` — Audio Unit の挿入と処理
- `MediaImporter.swift` — 形式判定と ffmpeg による変換
- `Exporter.swift` — AVAssetReader/Writer による MP4 書き出し
- `AppModel.swift` — アプリの状態と操作
- `ContentView.swift`, `TimelineViews.swift`, `AudioPanel.swift`, `PluginWindows.swift` — 画面
