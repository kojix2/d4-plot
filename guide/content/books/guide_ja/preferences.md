# 設定と言語

**設定**には言語、ツールバー形式、行の高さ、サイドバー表示、Y軸共有、ビン数、色、Y軸、基準線、アノテーション上限、公開遺伝子の取得元を保存します。取得元は UCSC が初期値で、Ensembl に変更できます。表示設定はD4ファイルを変更しません。

| 設定 | 用途 |
| --- | --- |
| **ビン数** | 拡大後の細部を表示するときに増やします。 |
| **Y軸の自動スケール** | 各トラックの形を表示します。 |
| **Y軸の固定** | 複数領域を同じ尺度で比較します。 |
| **ゼロを含める** | 基準線を表示します。 |
| **Y軸を共有** | トラック間の高さを比較します。 |
| **基準線** | しきい値を示します。 |

言語は**設定**で変更し、アプリを再起動してください。`--locale`はその起動に限り保存済みの言語より優先されます。**システム既定**はOSの言語を使い、未対応の言語は英語に切り替えます。

設定ファイルの場所:

- macOS: `~/Library/Application Support/D4 Plot/settings.json`
- Linux: `$XDG_CONFIG_HOME/d4-plot/settings.json`、未設定時は`~/.config/d4-plot/settings.json`
- Windows: `%APPDATA%\D4 Plot\settings.json`、使えない場合は`%LOCALAPPDATA%\D4 Plot\settings.json`、次に`~/D4 Plot/settings.json`

無効な設定値は初期値に戻ります。
