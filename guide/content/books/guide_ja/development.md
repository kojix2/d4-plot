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

## ネイティブUIランタイム

アプリケーションはネイティブUIスレッドで`UIng.main`を実行し、workerの結果を30 msごとに
pollします。ネイティブcallback内でファイルI/O、sleep、channel待機、worker joinを行っては
いけません。yieldするCrystalの処理は別のOSスレッドで再開する可能性があります。

変更されないデータを取り込み、バックグラウンド書き込みを`BackgroundIO`へ投入し、完了処理は
その`poll`から適用します。起動時の読み込みにはウィンドウ作成前に`UIRuntime.load`を使います。
このhelperは現在のOSスレッドをblockするため、UI callbackから呼び出してはいけません。
受理済みの書き込みはネイティブUI終了後に完了まで待機されます。
