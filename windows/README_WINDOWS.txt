EasyMovTrim for Windows
=======================

■ 動作環境
  Windows 10 / 11（64ビット）

■ インストール
  - インストーラー版: EasyMovTrim-x.x.x-windows-setup.exe を実行してください。
  - ZIP 版: 好きな場所に展開して EasyMovTrim.exe を実行してください。

  ※ 署名していないアプリのため、初回に「Windows によって PC が保護されました」と
     表示されることがあります。「詳細情報」→「実行」で起動できます。

■ 使い方
  - 動画をウィンドウにドロップするか、Ctrl+O で開きます
    （MP4 / MOV / MKV / WebM / AVI / FLV / WMV / MTS / MPG など）
  - 黄色いハンドルのドラッグ、または秒数の入力でトリム範囲を指定します
  - 右側で音量（フェーダー）、フェードイン/アウト（0.1〜5秒）、
    VST3 プラグインを設定できます
    （C:\Program Files\Common Files\VST3 にあるプラグインを一覧表示します）
  - 「軽量」か「高品質」を選んで「MP4 を書き出す…」を押します

  キー操作: Space 再生/停止、←→ コマ送り（Shift で1秒）、
            I / O 開始点/終了点、L ループ、Ctrl+E 書き出し

  プラグインの「画面」ボタンで開くプラグイン本来の画面は、閉じるまで
  メインウィンドウを操作できません（音は鳴り続けます）。
  「⚙」ボタンのパラメーター一覧は開いたまま操作できます。

■ 製作者・お問い合わせ
  Copyright © 2026 Naoto Iwaki
  ソースコード: https://github.com/wknt-mu/easymovtrim
  お問い合わせ・不具合報告: https://github.com/wknt-mu/easymovtrim/issues

■ ライセンス
  EasyMovTrim は GNU GPL v3 以降の条件で配布されるフリーソフトウェアです（LICENSE.txt）。
  いかなる保証もありません。
  FFmpeg（LGPL）、Qt / PySide6（LGPL）、pedalboard / JUCE（GPL v3）などを使用しています。
  詳細はメニューの「ヘルプ → ライセンス情報」、または THIRD_PARTY_NOTICES.md と
  _internal\licenses フォルダをご覧ください。
