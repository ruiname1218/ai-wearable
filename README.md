# XIAO nRF52840 Sense -> iPhone 音声文字起こし（Friend互換形式）

XIAO nRF52840 Senseのマイク音声をBLEでiPhoneへ連続送信し、iPhone側で`Speech`フレームワークを使って文字起こしするプロトタイプです。  
この版は`jhsu/Friend`のBLEフォーマットに合わせています。

## 構成

- `firmware/xiao_ble_mic_streamer/xiao_ble_mic_streamer.ino`
  - XIAO側ファーム（PDMマイク -> Friend形式BLE Notify）
- `ios/XiaoVoiceBridge/XiaoVoiceBridgeApp.swift`
- `ios/XiaoVoiceBridge/ContentView.swift`
- `ios/XiaoVoiceBridge/BluetoothSpeechViewModel.swift`
  - iPhoneアプリ本体（CoreBluetooth + Speech）

## 1. XIAO nRF52840 Sense の準備

1. Arduino IDEで以下をインストール
   - Board: `Seeed nRF52 Boards`
2. ボードを`Seeed XIAO nRF52840 Sense`に設定。
3. `firmware/xiao_ble_mic_streamer/xiao_ble_mic_streamer.ino`を書き込み。
4. シリアルモニタ(115200)で以下が出ればOK。
   - `Starting Friend-format BLE PCM streamer...`
   - `PDM microphone ready @ 16kHz`
   - `Ready. Continuous Friend-style audio notifications enabled.`

## 2. iPhoneアプリの準備（Xcode）

1. XcodeでiOS Appを作成（例: `XiaoVoiceBridge`）。
2. 下記ファイルで置換/追加。
   - `ios/XiaoVoiceBridge/XiaoVoiceBridgeApp.swift`
   - `ios/XiaoVoiceBridge/ContentView.swift`
   - `ios/XiaoVoiceBridge/BluetoothSpeechViewModel.swift`
3. `Info.plist`に以下キーを追加。
   - `NSSpeechRecognitionUsageDescription`
   - `NSBluetoothAlwaysUsageDescription`
   - `NSBluetoothPeripheralUsageDescription`
   - `UIBackgroundModes` に以下を追加
     - `bluetooth-central`
     - `audio`（前面/復帰時の認識安定化のため）
4. 実機iPhoneでビルド実行（SimulatorではBLE不可）。

## 3. 実行手順

1. XIAOの電源を入れる。
2. iPhoneアプリで`スキャン開始`。
3. `Friend`を`接続`。
4. `文字起こし開始`を押す。
5. 受信中に話すと、`文字起こし結果`へ反映されます。
6. 終了時は`停止`または`切断`。

## バックグラウンド動作について

- この実装は、アプリがバックグラウンドへ移行してもBLE受信継続を試みます（`bluetooth-central`前提）。
- iOSの制約で`Speech`認識タスクがバックグラウンド中に中断される場合があります。
- 中断した場合、受信データを一時保持し、前面復帰時に認識を再開するようにしています。
- 常時完全リアルタイムなバックグラウンド文字起こしを安定運用するには、サーバーSTT方式の併用が必要です。

## BLE仕様（Friend互換）

- Service UUID: `19B10000-E8F2-537E-4F6C-D104768A1214`
- Characteristic
  - Audio: `19B10001-E8F2-537E-4F6C-D104768A1214`（Read/Notify）
  - Format: `19B10002-E8F2-537E-4F6C-D104768A1214`（Read）
- Format値
  - `1` = PCM16LE @ 8kHz（この実装）
- Audio Notify payload
  - `[0..1]`: packet id (LE)
  - `[2]`: chunk index
  - `[3..]`: PCM bytes

## 動かない場合のチェック

- iPhone設定でアプリの`音声認識`許可がONか。
- iPhoneのBluetoothがONか。
- ArduinoのBoard設定が`XIAO nRF52840 Sense`か。
- 画面で`音声受信準備: OK`になっているか。
- `受信パケット`が増えるか。
- `音量RMS`が0付近のままではないか。

## 注意

- これは簡易プロトタイプです。BLE混雑環境では欠損が増え、認識精度が下がります。
- `Friend`本家と完全同一実装ではなく、Arduino環境で同じBLE wire formatを再現したものです。
