# 開発

[インストール](installation.md)に記載したネイティブ依存関係を導入し、次のチェックを実行します。

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

CI workflowではUbuntu、macOS、Windows UCRT64でspecとrelease buildを実行します。
ネイティブUIのsmoke testはグラフィカルセッションで実行してください。

```sh
crystal run scripts/ui-smoke.cr
```

アプリケーションアイコンを変更するには、`assets/d4-plot.png`を透明背景の正方形PNGで
置き換え、ImageMagickを導入した環境で`bash scripts/refresh-icons.sh`を実行します。
macOSアイコンはアプリケーションバンドルのパッケージ時に生成されます。

## 診断ログ

Crystal標準ライブラリの`Log`を使用します。通常は`INFO`で、起動前に
`LOG_LEVEL=DEBUG`を設定すると、読み取り方式、キャッシュの利用、リクエストの取消、
ファイルパス、ゲノム座標、例外のバックトレースも記録します。`LOG_LEVEL=NONE`で
アプリケーションの診断ログを無効化できます。不正なレベルは警告を出して`INFO`に戻します。

デスクトップ版は次のディレクトリに`d4-plot-<プロセスID>.log`を保存します。

- Windows: `%LOCALAPPDATA%\D4 Plot\logs`。未設定時は`%APPDATA%`、ホームディレクトリの順に使用。
- macOS: `~/Library/Logs/D4 Plot`。
- Linux: `$XDG_STATE_HOME/d4-plot/logs`。未設定時は`~/.local/state/d4-plot/logs`。

`d4-plot serve`と`d4-plot-server`は標準エラー出力へ記録します。ビューアーのURLと
ヘルプは標準出力へ表示します。どちらも`D4_PLOT_LOG_FILE`で保存先を指定できます。
同時起動するプロセスには別々の保存先を指定してください。ファイルは約5 MiBで
ローテーションし、過去2世代（`.1`、`.2`）を保持します。容量はプロセス／保存先ごとに
約15 MiBです。過去のプロセスのログは手動で削除するまで残り、ディレクトリ全体の
容量制限はありません。ログファイルを開けない場合は標準エラー出力へ切り替えます。

PowerShellでの例:

```powershell
$env:LOG_LEVEL = 'DEBUG'
$env:D4_PLOT_LOG_FILE = "$env:TEMP\d4-plot-debug.log"
.\bin\d4-plot.exe
# 問題を再現後、アプリを終了すると保留中のログも書き出されます。
Remove-Item Env:LOG_LEVEL, Env:D4_PLOT_LOG_FILE
```

各ログには時刻、レベル、プロセスID、出力元、固定のイベント名、付加情報が含まれます。
ファイル／表示の読み込みとHTTP通信は`request_id`、変換とバックグラウンド書き込みは
`job_id`で追跡します。生成するIDはプロセス内で一意です。HTTP応答の
`X-Request-ID`から対応するサーバーログを検索できます。通常のエラーは例外の種類を
記録し、DEBUGではエラーが発生したスレッド上で取得した例外とバックトレースを記録します。
DEBUGログにはパス、トラック名、ゲノム座標を含むため、共有前に内容を確認してください。
接続トークン付きURLはアプリケーションログから除外・マスクします。標準出力に表示する
URLは引き続き接続に使えるリンクです。

ログの配送には上限付きキューとネイティブ同期を使い、GUIコールバック内では配送待ちの
yieldやログファイルI/Oを行いません。キューが満杯の場合は新しいログを破棄し、
`log.entries_dropped`で件数を報告します。書き込み失敗時はその出力を停止し、可能なら
標準エラー出力へ通知します。終了時はUIの破棄後に受理済みのログを書き出します。
強制終了では未出力ログが失われることがあります。塩基・bin単位や再描画・マウス移動の
ログは出力しません。

## ネイティブUIランタイム

アプリケーションはネイティブUIスレッドで`UIng.main`を実行し、workerの結果を30 msごとに
pollします。ネイティブcallback内でファイルI/O、sleep、channel待機、worker joinを行っては
いけません。yieldするCrystalの処理は別のOSスレッドで再開する可能性があります。

変更されないデータを取り込み、バックグラウンド書き込みを`BackgroundIO`へ投入し、完了処理は
その`poll`から適用します。起動時の読み込みにはウィンドウ作成前に`UIRuntime.load`を使います。
このhelperは現在のOSスレッドをblockするため、UI callbackから呼び出してはいけません。
受理済みの書き込みはネイティブUI終了後に完了まで待機されます。

`BackgroundIO`は`Concurrent`実行コンテキストを使用します。IGV DesktopへのHTTP通信も
ここで実行し、結果だけをUIスレッドの`poll`で反映します。macOSでは特に、ネットワーク
I/Oを行うfiberからUIngのGUIを操作しないでください。HTTP応答の本文は常に存在するとは
限りません。たとえばIGV Desktopが204を返した場合、`body_io`を読まずに成功として扱います。
