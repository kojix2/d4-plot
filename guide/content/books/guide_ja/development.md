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

buildワークフローはWindows・macOS・Linuxで通常の`d4-plot`実行ファイルをビルドし、
その実行ファイルを`kojix2/window-screenshot-action@main`で撮影します。
撮影用アプリを別途コンパイルすることはありません。ビルド完了後にdocsワークフローを
呼び出し、画像アーティファクトからサイトを生成します。docs側でCrystalを導入したり、
アプリを再コンパイルしたりする処理はありません。

各OSで日英の全体表示・拡大表示・D4作成画面を生成し、
`screenshots/<windows|macos|ubuntu>/<en|ja>/`に保存します。
READMEとガイドには3 OS分を比較表で掲載します。

撮影モードはリポジトリのルートにある`spec/fixtures/rust-multitrack.d4`を読み、
一時的なBEDとBAMを生成します。読み込み完了後に対象ウィンドウを表示し、
Actionが撮影とプロセス終了を担当します。

ビルド済みの実行ファイルで確認する場合は、グラフィカルセッションで
リポジトリのルートから実行します。

```sh
D4_PLOT_SCREENSHOT_SCENE=overview bin/d4-plot
D4_PLOT_SCREENSHOT_SCENE=inspect D4_PLOT_SCREENSHOT_LOCALE=ja bin/d4-plot
D4_PLOT_SCREENSHOT_SCENE=create-d4 bin/d4-plot
```

WindowsではPowerShellで同じ環境変数を設定して`bin/d4-plot.exe`を実行します。
Actionから引数なしで起動する場合は、同じ実行ファイルを`guide-overview`、
`guide-inspect`、`guide-create-d4`という名前でコピーし、
`D4_PLOT_SCREENSHOT_SCENE=auto`で画面を選びます。
環境変数を設定しない通常の起動動作は変わりません。

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
