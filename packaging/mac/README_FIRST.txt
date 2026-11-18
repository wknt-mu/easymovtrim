EasyMovTrim for Mac
===================

■ インストール
  「EasyMovTrim.app」を「Applications」フォルダへドラッグしてください。
  対応OS: macOS 14 (Sonoma) 以降 / Apple Silicon・Intel 両対応

■ 初めて開くとき（重要）
  このアプリは Apple の公証（notarization）を受けていないため、
  初回は「開発元を確認できないため開けません」などと表示されます。
  次の手順で一度だけ許可してください。

  1. アプリケーションフォルダの EasyMovTrim をダブルクリックする
     （警告が出たら「完了」または「キャンセル」で閉じる）
  2. 「システム設定」→「プライバシーとセキュリティ」を開く
  3. 下の方にある「"EasyMovTrim" は開発元を確認できないため…」の横の
     「このまま開く」をクリックし、パスワードを入力する
  4. もう一度 EasyMovTrim を開き、「開く」を選ぶ

  ※ うまくいかない場合は「ターミナル」で次を実行してから開いてください。
     xattr -dr com.apple.quarantine /Applications/EasyMovTrim.app

■ 使い方
  - 動画をウィンドウにドロップするか、⌘O で開きます
    （MP4 / MOV / MKV / WebM / AVI / FLV / WMV / MTS / MPG など）
  - 黄色いハンドルのドラッグ、または秒数の入力でトリム範囲を指定します
  - 右側で音量（フェーダー）、フェードイン/アウト（0.1〜5秒）、
    Audio Unit プラグインを設定できます
  - 「軽量」か「高品質」を選んで「MP4 を書き出す…」を押します

  キー操作: Space 再生/停止、←→ コマ送り（Shift で1秒）、
            I / O 開始点/終了点、L ループ、⌘E 書き出し

■ 製作者・お問い合わせ
  Copyright © 2026 Naoto Iwaki
  ソースコード: https://github.com/wknt-mu/easymovtrim
  お問い合わせ・不具合報告: https://github.com/wknt-mu/easymovtrim/issues

■ ライセンス
  EasyMovTrim は GNU GPL v3 以降の条件で配布されるフリーソフトウェアです（LICENSE）。
  いかなる保証もありません。
  同梱の ffmpeg / ffprobe は LGPL v2.1 の FFmpeg です（licenses/LGPL-2.1.txt）。
  詳しくは THIRD_PARTY_NOTICES.md、またはアプリの「ヘルプ」→「ライセンス情報」をご覧ください。
