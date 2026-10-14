# インストール

## リリースパッケージ

[GitHub Releases](https://github.com/kojix2/d4-plot/releases)では、リリースworkflowが
生成した次のパッケージを配布します。

- 64ビットWindows用のポータブルZIPとインストーラー
- Apple SiliconおよびIntel macOS用のアプリケーションバンドル
- Ubuntuおよび互換システム向けのAMD64 Debianパッケージ

## ソースからのビルド

D4 PlotにはCrystal 1.21以降、Shards、Git、
[UIngのネイティブ依存関係](https://kojix2.github.io/uing/books/guide_ja/installation.html)、
HTSlib、pkg-configが必要です。

macOSでは次をインストールします。

```sh
brew install htslib pkg-config
```

DebianまたはUbuntuでは次をインストールします。

```sh
sudo apt install libhts-dev pkg-config
```

続いてD4 Plotをビルドします。

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

WindowsビルドではMSYS2 UCRT64と静的リンクしたHTSlibを使用します。必要なパッケージは
[Windowsセットアップアクション](https://github.com/kojix2/d4-plot/blob/main/.github/actions/setup-windows/action.yml)
に記載されています。その環境から次を実行します。

```sh
shards install --frozen
bash scripts/build-windows.sh
```

## アプリケーションの起動

1個以上のD4ファイルに加え、初期領域やインターフェース言語を指定できます。

```sh
bin/d4-plot sample.d4
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
```

対応する言語コードは`bin/d4-plot --help`で確認できます。Windowsのソースビルドでは
実行ファイルは`bin/d4-plot.exe`です。
