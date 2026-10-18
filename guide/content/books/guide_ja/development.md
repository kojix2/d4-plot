# 開発

[インストール](installation.md)にあるネイティブ依存関係を導入し、次を実行します。

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

CIはUbuntu、macOS、Windows UCRT64でビルドします。UIのsmoke testはグラフィカルセッションで実行します。

```sh
crystal run scripts/ui-smoke.cr
```

アイコンは`assets/d4-plot.png`を透明背景の正方形PNGに置き換え、ImageMagickを入れて`bash scripts/refresh-icons.sh`を実行します。macOSアイコンはパッケージ時に生成します。

## ガイドのスクリーンショット

macOSでNicolinoサイトをビルドしてから、リポジトリのルートで実行します。

```sh
mkdir -p guide/output/screenshots
crystal run scripts/guide-screenshots.cr -- guide/output/screenshots/en en
crystal run scripts/guide-screenshots.cr -- guide/output/screenshots/ja ja
```

実行前に言語別ディレクトリが存在しないことを確認してください。スクリプトは`spec/fixtures/rust-multitrack.d4`を読み、例に使うBEDとBAMを生成します。docsワークフローはmacOSで日英両方を撮影し、Pagesに追加します。

## ログ

`LOG_LEVEL=DEBUG`で読み取り方式、キャッシュ、取消、パス、座標、バックトレースを記録します。`LOG_LEVEL=NONE`で無効化します。初期値は`INFO`です。デスクトップ版は`d4-plot-<process-id>.log`を次へ保存します。

- Windows: `%LOCALAPPDATA%\D4 Plot\logs`、次に`%APPDATA%`、ホーム
- macOS: `~/Library/Logs/D4 Plot`
- Linux: `$XDG_STATE_HOME/d4-plot/logs`、未設定時は`~/.local/state/d4-plot/logs`

サーバーのログは標準エラー出力、URLとヘルプは標準出力です。`D4_PLOT_LOG_FILE`でどちらの実行ファイルも保存先を指定できます。約5 MiBでローテーションし、2世代を保持します。過去のプロセスのログは手動で削除します。ファイルを開けない場合は標準エラー出力へ切り替えます。

ファイル読み込みとHTTPには`request_id`、変換とバックグラウンド書き込みには`job_id`を使います。HTTP応答には`X-Request-ID`があります。DEBUGログにはパス、トラック名、座標が含まれるため、共有前に確認してください。接続トークン付きURLはログに残しませんが、標準出力のURLは接続に使用できます。

上限付きログキューが満杯になると新しいログを破棄し、`log.entries_dropped`で報告します。通常終了時は受理済みログを書き出しますが、強制終了では失われる場合があります。

## UIスレッド

`UIng.main`はネイティブUIスレッドで動き、30 msごとにworkerの結果を取り込みます。ネイティブcallbackでファイルI/O、sleep、channel待機、worker joinを行わないでください。yieldしたfiberが別のOSスレッドで再開する可能性があります。

起動時の読み込みはウィンドウ作成前に`UIRuntime.load`を使います。書き込みとIGV DesktopへのHTTP通信は`BackgroundIO`へ送り、結果をUIスレッドの`poll`で反映します。受理済み書き込みはUI破棄後に完了まで待機します。IGV DesktopのHTTP 204応答には本文がないため、`body_io`を読まずに処理します。
