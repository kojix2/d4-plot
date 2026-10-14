# 設定と言語

D4 Plotは選択した言語と表示設定を保存します。保存対象にはツールバー形式、トラックの高さ、
サイドバー表示、Y共有、ビン数、シグナル色、Y軸設定、基準線、アノテーション上限が含まれます。

設定ファイルの場所は次のとおりです。

- macOS: `~/Library/Application Support/D4 Plot/settings.json`
- Linux: `$XDG_CONFIG_HOME/d4-plot/settings.json`、未設定時は
  `~/.config/d4-plot/settings.json`
- Windows: `%APPDATA%\D4 Plot\settings.json`。利用できない場合は
  `%LOCALAPPDATA%\D4 Plot\settings.json`、続いて`~/D4 Plot/settings.json`

設定ファイルが壊れていたり一部が古かったりしても起動を妨げず、無効な項目には
デフォルト値を使用します。

**システム既定**はmacOSとWindowsではOSの言語設定に従います。Linuxでは`LC_ALL`、
`LC_MESSAGES`、`LANGUAGE`、`LANG`の順に確認します。未対応の言語は英語になります。
保存した言語はシステム設定より優先され、`--locale`はその実行に限り両方より優先されます。
**設定**で変更した言語はD4 Plotの再起動後に反映されます。
