# EasyMovTrim — ライセンスと権利表記 / License & Notices

## EasyMovTrim 本体

Copyright © 2026 Naoto Iwaki

このプログラムはフリーソフトウェアです。GNU General Public License version 3
またはそれ以降のバージョン（GPL-3.0-or-later）の条件で再配布・改変できます。
このプログラムは有用であることを願って配布されますが、**いかなる保証もありません**。
詳しくは同梱の `LICENSE`（GPL v3 全文）をご覧ください。

- ソースコード: https://github.com/wknt-mu/easymovtrim
- お問い合わせ・不具合報告: https://github.com/wknt-mu/easymovtrim/issues

This program is free software: you can redistribute it and/or modify it under the terms of
the GNU General Public License as published by the Free Software Foundation, either version 3
of the License, or (at your option) any later version. It is distributed WITHOUT ANY WARRANTY.

---

## 同梱ソフトウェア（macOS 版）

| ソフトウェア | バージョン | ライセンス | 本文 |
|---|---|---|---|
| FFmpeg（`ffmpeg`, `ffprobe`） | 8.0.1 | LGPL v2.1 以降 | `licenses/LGPL-2.1.txt` |

- FFmpeg は https://ffmpeg.org/ のソフトウェアです。GPL / nonfree の部品を含めずにビルドしています
  （設定は `scripts/build_ffmpeg_mac.sh`）。macOS 標準のライブラリ以外とはリンクしていません。
- 使用したソースコード `ffmpeg-8.0.1.tar.xz` は、配布ファイルと同じ GitHub Releases に添付しています。
- FFmpeg は独立した実行ファイルとして `EasyMovTrim.app/Contents/MacOS/` にあり、利用者が差し替えられます。

## 同梱ソフトウェア（Windows 版）

| ソフトウェア | ライセンス | 本文 |
|---|---|---|
| FFmpeg（`ffmpeg.exe`, `ffprobe.exe`、BtbN/FFmpeg-Builds の LGPL ビルド） | LGPL v2.1 以降（同梱ライブラリを含む） | `ffmpeg/FFMPEG_LICENSE.txt`, `licenses/LGPL-2.1.txt` |
| pedalboard 0.9.26（Spotify AB） | GPL v3 | `licenses/GPL-3.0.txt`, `licenses/pedalboard-NOTICE.txt` |
| JUCE（pedalboard に含まれる、Raw Material Software Limited） | GPL v3 | `licenses/GPL-3.0.txt` |
| VST3 SDK（pedalboard に含まれる、Steinberg Media Technologies GmbH） | GPL v3 | `licenses/GPL-3.0.txt` |
| pedalboard に組み込まれたその他の部品: Rubber Band Library、FFTW（GPL）、LAME、libgsm（LGPL ほか）、libFLAC、pybind11（BSD） | 各ライセンス（全体として GPL v3 で配布） | pedalboard のソース一式に同梱 |
| Qt 6 / Qt for Python（PySide6, Shiboken6）6.12.0（The Qt Company） | LGPL v3 | `licenses/LGPL-3.0.txt`, `licenses/GPL-3.0.txt` |
| Qt Multimedia が使用する FFmpeg ライブラリ（PySide6 に同梱） | LGPL v2.1 以降 | `licenses/LGPL-2.1.txt` |
| NumPy | BSD 3-Clause ほか | `licenses/numpy-BSD-3.txt`, `numpy-*.dist-info/licenses/` |
| python-sounddevice（Matthias Geier） | MIT | `licenses/sounddevice-MIT.txt` |
| PortAudio（Ross Bencina, Phil Burk） | MIT | `licenses/PortAudio-MIT.txt` |
| CFFI | MIT-0 | `licenses/cffi-MIT-0.txt` |
| pycparser（Eli Bendersky） | BSD 3-Clause | `licenses/pycparser-BSD-3.txt` |
| Python（Python Software Foundation） | PSF License | `licenses/Python-PSF.txt` |

- Qt / PySide6 のライブラリは独立した DLL として同梱しており、利用者が差し替えられます（LGPL v3）。
  Qt 内部で使われているサードパーティ部品の一覧: https://doc.qt.io/qt-6/licenses-used-in-qt.html
- PortAudio は ASIO を含まない版のみを同梱しています。

## ソースコードの入手方法（GPL / LGPL の部品）

1. **EasyMovTrim 本体:** https://github.com/wknt-mu/easymovtrim （各リリースのタグ）
2. **FFmpeg（macOS 版・Windows 版）、pedalboard（JUCE などのサブモジュールを含む）:** 配布ファイルと同じ
   GitHub Releases に、使用したソースを添付しています
3. **Windows 版 FFmpeg のビルド手順と同梱ライブラリ:** https://github.com/BtbN/FFmpeg-Builds
4. **Qt / PySide6 6.12.0:** https://download.qt.io/official_releases/QtForPython/ および https://download.qt.io/official_releases/qt/6.12/
5. **JUCE:** https://github.com/juce-framework/JUCE / **VST3 SDK:** https://github.com/steinbergmedia/vst3sdk

上記で入手できない部品があれば、https://github.com/wknt-mu/easymovtrim/issues からご連絡ください。
配布から 3 年間、対応する完全なソースコードを実費以内（無償を予定）で提供します。

## 商標

- FFmpeg is a trademark of Fabrice Bellard.
- VST is a registered trademark of Steinberg Media Technologies GmbH.
- Qt is a registered trademark of The Qt Company Ltd.
- Mac, macOS は Apple Inc. の、Windows は Microsoft Corporation の商標です。
