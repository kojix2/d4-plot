# コマンドライン

全オプションは`d4-plot --help`または`d4-plot-server --help`で確認できます。パスは絶対パスまたは現在のディレクトリからの相対パスを使います。

## デスクトップ版

```sh
d4-plot sample.d4
d4-plot sample1.d4 sample2.d4
d4-plot --region chr1:1,000,000-2,000,000 sample.d4
d4-plot --locale ja sample.d4
```

領域は1始まり・両端を含みます。`chr1:100`は1塩基、`chr1`は染色体全体です。`--locale`はその起動に限り保存済みの言語より優先されます。

## ブラウザサーバー

`d4-plot serve`と`d4-plot-server`は同じオプションを受け付けます。

```sh
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --genome hg38 --open
d4-plot-server --reference reference.fa --reference-index reference.fa.fai sample.d4
```

サーバーはトークン付きURLを表示し、`127.0.0.1`で待ち受けます。終了はCtrl-Cです。URLは同じコンピューターで開き、共有しないでください。`--open`でブラウザを起動できなくても、サーバーは動き続けます。

参照配列は次のうち1つを選びます。

| オプション | 参照配列 |
| --- | --- |
| `--genome ID` | `hg38`などの公開IGVプリセット |
| `--reference PATH` | ローカルFASTAまたはIGV genome JSON。FASTAには`.fai`が必要です。別の場所なら`--reference-index PATH`を使います。 |
| `--contigs-only` | D4の染色体名と長さのみ。塩基配列はありません。 |

D4を指定し、参照オプションを省いた場合はD4の染色体情報を使います。D4を指定しない場合は`--genome`か`--reference`が必要です。D4の染色体情報だけでは作成元のアセンブリは分かりません。公開プリセットは公開ホストから参照データを取得します。参照へのアクセスをローカルに限定するにはFASTA/FAIを使います。JSON参照が指すファイルにはブラウザからアクセスできる必要があります。

| オプション | 用途 |
| --- | --- |
| `--region REGION` | 初期領域。例: `chr1:100-200` |
| `--locale LOCALE` | ブラウザの言語 |
| `--port PORT` | ループバックポート。`0`で空きポートを選択 |
| `--open` | 起動後にURLを開く |

WindowsでURLをコピーする場合はターミナルから`d4-plot-server`を実行します。macOSアプリ内の実行ファイルは`d4-plot.app/Contents/MacOS/d4-plot-server`です。トラックと参照の動作は[IGVとの連携](igv-integration.md)を参照してください。
