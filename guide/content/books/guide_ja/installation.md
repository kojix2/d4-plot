# インストール

[GitHub Releases](https://github.com/kojix2/d4-plot/releases)からOSに合うパッケージを選びます。

- Windows x64: ポータブルZIPまたはインストーラー
- macOS: Apple SiliconまたはIntel用アプリ
- Ubuntu互換AMD64: Debianパッケージ

インストールして**D4 Plot**を起動します。リリース版にはCrystalやShardsは不要です。Debianパッケージは依存ライブラリを導入し、Windows/macOS版は同梱します。

## ソースからビルドする

Crystal 1.21以降、Shards、Git、[UIngのネイティブ依存関係](https://kojix2.github.io/uing/books/guide_ja/installation.html)、HTSlib、pkg-configを用意します。

```sh
# macOS
brew install htslib pkg-config

# Debian/Ubuntu
sudo apt install libhts-dev pkg-config
```

ビルド:

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

Windowsでは[セットアップアクション](https://github.com/kojix2/d4-plot/blob/main/.github/actions/setup-windows/action.yml)のパッケージを入れたMSYS2 UCRT64環境で実行します。

```sh
shards install --frozen
bash scripts/build-windows.sh
```

## ターミナルから起動する

```sh
bin/d4-plot sample.d4
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
```

言語コードは`bin/d4-plot --help`で確認できます。Windowsのソースビルドは`bin/d4-plot.exe`です。画面操作は[まずここから](quick-start.md)を参照してください。
