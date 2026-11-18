# Third-Party Notices / 同梱ソフトウェアのライセンス

EasyMovTrim には以下のソフトウェアが含まれています。

## macOS 版

### FFmpeg 8.0.1（`ffmpeg`, `ffprobe`）
- ライセンス: GNU Lesser General Public License v2.1 以降（LGPL）
- 入手元: https://ffmpeg.org/
- ソースコード: https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz
- ビルド方法: このリポジトリの `scripts/build_ffmpeg_mac.sh`（GPL / nonfree の部品は含めていません）
- FFmpeg は別プロセスの実行ファイルとして同梱しています。差し替える場合は
  `EasyMovTrim.app/Contents/MacOS/ffmpeg` と `ffprobe` を置き換えてください。

## Windows 版

### FFmpeg（`ffmpeg.exe`, `ffprobe.exe`）
- ライセンス: GNU General Public License v3（GPL。libx264 などを含むビルド）
- 入手元: https://github.com/BtbN/FFmpeg-Builds （ビルド済みバイナリ）
- ソースコード: https://github.com/FFmpeg/FFmpeg および上記リポジトリのビルドスクリプト

### pedalboard（VST3 プラグインの読み込みと処理）
- ライセンス: GNU General Public License v3
- 入手元 / ソースコード: https://github.com/spotify/pedalboard
- JUCE（GPLv3 として利用）と Steinberg VST3 SDK を含みます。

### Qt for Python（PySide6）
- ライセンス: GNU Lesser General Public License v3
- 入手元 / ソースコード: https://www.qt.io/qt-for-python

### その他
- NumPy — BSD 3-Clause License — https://numpy.org/
- python-sounddevice — MIT License — https://github.com/spatialaudio/python-sounddevice
- PortAudio — MIT License — https://www.portaudio.com/
- Python — Python Software Foundation License — https://www.python.org/

Windows 版は GPL v3 のソフトウェア（pedalboard）を組み込んでいるため、
Windows 版を配布する場合は、このアプリのソースコードも GPL v3 の条件で入手できるようにする必要があります。

VST is a trademark of Steinberg Media Technologies GmbH.
