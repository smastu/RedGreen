# RedGreen

窓の赤・緑ボタンの動きを変える、メニューバー常駐の小さなアプリ（Swift、1ファイル）。

- **緑ボタン**：全画面ではなく、画面いっぱい（Dock とメニューバーを除く）に広げる。もう一度押すと元の大きさに戻る。⌥ を押しながらなら macOS 標準の動き
- **最後の窓を閉じたら終了**（Swift Quit と同じ）：赤ボタンでも ⌘W でも、アプリの普通の窓が 0 になったらアプリを終了する
- 終了させないアプリ：`~/Library/Application Support/RedGreen/exclude.txt`（アプリ名かバンドル ID。初期値は Finder・MSLite・LiteDeck・ResourceWatch）
- メニューバーのアイコンから、それぞれのオン・オフ、除外リストの編集、ログイン時の起動（LaunchAgent `local.matsumoto.RedGreen`）

アクセシビリティの許可が必要（システム設定 → プライバシーとセキュリティ → アクセシビリティ）。

## ビルド
`./build.sh` → `~/Applications/RedGreen.app`。
自己署名の証明書「Shimpei Local Code Signing」があればそれで署名するので、作り直してもアクセシビリティの許可が消えない。

## 注意
- 赤ボタンのクリックと ⌘W を見張り、閉じたあと（0.7・2・5 秒後）にそのアプリの普通の窓が 0 なら終了。メニューの「ウインドウを閉じる」やスクリプトで閉じた場合は対象外（アクセシビリティの「窓が消えた」知らせはアプリによって届かないため、この方式にした）
- 記録：~/Library/Logs/RedGreen.log
