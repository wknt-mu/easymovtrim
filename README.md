# EasyMovTrim

動画トリムアプリです。Mac 版と Windows 版があります。

| | Mac 版 | Windows 版 |
|---|---|---|
| 技術 | SwiftUI + AVFoundation（`Sources/`） | Python + Qt (PySide6)（`windows/`） |
| プラグイン | Audio Unit (AUv2 / AUv3) | VST3 |
| 配布物 | `EasyMovTrim-x.x.x-mac.dmg`（Apple Silicon / Intel） | `EasyMovTrim-x.x.x-windows-setup.exe` / `.zip`（x64） |
| ffmpeg | ソースからビルドした LGPL 版を同梱 | BtbN/FFmpeg-Builds の GPL 版を同梱 |

機能・操作・音声処理（プラグイン → フェーダー → フェード → メーター）は両方とも同じです。

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

## 配布用パッケージの作り方

### GitHub Actions でまとめて作る（推奨）

`.github/workflows/build.yml` で Mac 版と Windows 版を両方ビルドします。

1. GitHub にリポジトリを作り、このフォルダを push します
2. **手動で作る:** GitHub の「Actions」→「Build packages」→「Run workflow」。完了後、実行結果のページの Artifacts から DMG と Windows 版をダウンロードできます
3. **リリースとして公開する:** バージョンのタグを push すると、GitHub Releases に DMG・インストーラー・ZIP が添付されます

```bash
git tag v1.0.0
git push origin v1.0.0
```

### Mac で手元で作る

```bash
scripts/build_ffmpeg_mac.sh   # 初回のみ。ffmpeg 8.0.1 をソースから LGPL 版でビルド（数分）
scripts/package_mac.sh        # dist/EasyMovTrim-1.0.0-mac.dmg ができる
```

Apple の Developer ID で署名していないため、受け取った人は初回だけ「システム設定 → プライバシーとセキュリティ → このまま開く」で許可が必要です（手順書を DMG に同梱しています）。Developer ID を持っている場合は `SIGN_IDENTITY="Developer ID Application: ..."` を付けてビルドし、`xcrun notarytool` で公証すると警告なしで開けるようになります。

### Windows で手元で作る

Python 3.12（64bit）と、必要なら Inno Setup 6 を入れた Windows で:

```powershell
powershell -ExecutionPolicy Bypass -File windows\build_windows.ps1 -Version 1.0.0
```

`dist\` に ZIP 版とインストーラーができます。

### ライセンス上の注意

- Mac 版に同梱している ffmpeg は LGPL です
- Windows 版は GPL v3 の pedalboard（VST3 の読み込みに使用）を組み込んでいるため、Windows 版を配布するときは、このアプリのソースコードも GPL v3 の条件で公開する必要があります（GitHub で公開リポジトリにするなど）
- 詳細は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

## Mac 版のビルド（開発用）

Xcode（コマンドラインツール）が入った macOS 14 以降で:

```bash
./build.sh
```

`build/EasyMovTrim.app` ができます。Intel Mac でも動くユニバーサル版は `UNIVERSAL=1 ./build.sh`。

### ffmpeg について

MP4/MOV 以外の形式を開くときに ffmpeg を使います。探す順番は次のとおりです。

1. アプリ内 `EasyMovTrim.app/Contents/MacOS/ffmpeg`
2. `/opt/homebrew/bin`, `/usr/local/bin` など

`vendor/ffmpeg` と `vendor/ffprobe` があると、ビルド時にアプリ内へ同梱されます。`scripts/build_ffmpeg_mac.sh` で、macOS 標準のライブラリだけに依存する LGPL 版を作れます（Homebrew 版は外部ライブラリに依存するため、同梱しても他の Mac では動きません）。

## コマンドラインでの書き出し

```bash
build/EasyMovTrim.app/Contents/MacOS/EasyMovTrim --export in.mkv out.mp4 \
  --in 2.5 --out 7.5 --quality light --fadein 1 --fadeout 2 --volume -6 --plugin "AUDelay"
build/EasyMovTrim.app/Contents/MacOS/EasyMovTrim --list-plugins
```

## Windows 版を Mac / Windows でソースから動かす（開発用）

```bash
cd windows
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m easymovtrim_win            # 画面
.venv/bin/python -m easymovtrim_win --export in.mkv out.mp4 --in 1 --out 5 --quality light
```

## 構成

`Sources/EasyMovTrim/`（Mac 版）

- `AudioProcessing.swift` — 音声タップ（音量・フェード・メーター）
- `EffectChain.swift` — Audio Unit の挿入と処理
- `MediaImporter.swift` — 形式判定と ffmpeg による変換
- `Exporter.swift` — AVAssetReader/Writer による MP4 書き出し
- `AppModel.swift` — アプリの状態と操作
- `ContentView.swift`, `TimelineViews.swift`, `AudioPanel.swift`, `PluginWindows.swift` — 画面

`windows/easymovtrim_win/`（Windows 版）
- `audio_engine.py` — 再生・プラグイン・音量・フェード・メーター
- `media.py` — ffmpeg / ffprobe の呼び出し
- `exporter.py` — MP4 書き出し
- `ui.py`, `widgets.py` — 画面
