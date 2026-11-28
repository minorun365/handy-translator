# 開発者向けの情報

## ビルド

Xcode 27 と XcodeGen が必要です。

```bash
brew install xcodegen
xcodegen generate
open HandyTranslator.xcodeproj
```

ターゲットは2つあります。HandyTranslator が iPhone 用（iOS 26.4 以降）で、HandyTranslatorMac は同じコードを Mac で動かす検証用です。Apple の音声認識と翻訳はシミュレータで動かないため、iPhone の実機か Mac のターゲットで試します。

## 音声ファイルで試す

設定画面の「音声ファイルで試す」から、録音済みの講演を実時間の速さで流せます。マイクと同じ経路で字幕と要約を作るので、会場に行かなくても動きを確かめられます。

TestAudio/keynote-sample.txt は、検証用に書いた架空の講演原稿です。読み上げ音声にして使います。

## 検証用の環境変数

Xcode のスキームで環境変数を渡すと、起動時の設定を切り替えられます。

| 変数 | 働き |
|---|---|
| `HANDY_AUDIO_FILE` | 起動と同時に音声ファイルを実時間の速さで流す |
| `HANDY_API_KEY` | Bedrock の API キーを一時的に渡す |
| `HANDY_CLOUD` | `1` か `0` で、クラウドの訳し直しを入・切にする |
| `HANDY_WHISPER` | `1` か `0` で、Whisper の聞き直しを入・切にする |
| `HANDY_LOCAL_REFINE` | `1` か `0` で、端末内モデルの訳し直しを入・切にする |
| `HANDY_WHISPER_MODEL` | Whisper のモデル名を指定する |
| `HANDY_REPLAY` | 保存済みの記録（JSON）を画面に出す |
| `HANDY_SAVE` | `1` にすると、`HANDY_REPLAY` で読み込んだ記録を停止時と同じ経路で保存・送信する |
| `HANDY_S3_BUCKET` | S3 のバケット名を一時的に渡す |
| `HANDY_S3_KEY` | S3 のキーを一時的に渡す |
| `HANDY_SHEET` | `sessions`・`settings`・`history` のどれかの画面を起動時に開く |

記録は停止時に、開始日時を名前にした JSON としてアプリの書類フォルダへ保存されます。

## 自分用のビルドに設定を入れておく

`Sources/Preset.plist` を置いてビルドすると、起動時にその値を設定へ入れます。キーは端末のキーチェーンへ保存され、同じ内容は一度だけ入ります。このファイルは git 管理外です。

| キー | 入る設定 |
|---|---|
| `BedrockAPIKey` | Bedrock の API キー |
| `Region` | Bedrock のリージョン |
| `S3Credentials` | S3 のキー（`アクセスキーID:シークレット`） |
| `S3Bucket` | S3 のバケット名 |
| `S3Region` | S3 のリージョン |

## 試験的な機能

設定画面の「試験的な機能」には、確定した発話を端末内の Whisper（WhisperKit）で聞き直す設定と、端末内モデルで訳し直す設定があります。どちらも既定は切です。Whisper の聞き直しは本体がかなり熱くなるので、長時間の講演では使わないほうが安全です。電池の減りと本体の熱は1分ごとに記録し、設定画面の「計測」に出します。
