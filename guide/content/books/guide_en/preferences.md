# Preferences and languages

**Settings** saves language, toolbar mode, row height, sidebar visibility, shared Y, bin count, colors, Y scale, reference lines, and annotation limit. Display settings do not change D4 files.

| Setting | Use |
| --- | --- |
| **Bin count** | Increase to see detail after zooming in. |
| **Automatic Y scale** | Show each track's shape. |
| **Fixed Y scale** | Compare regions at the same height scale. |
| **Include zero** | Show the baseline. |
| **Shared Y** | Compare heights across visible tracks. |
| **Reference lines** | Mark a threshold. |

Change the language in **Settings** and restart. `--locale` overrides the saved language for one run. If no language is saved, **System default** uses the OS language; unsupported languages fall back to English.

Settings are stored at:

- macOS: `~/Library/Application Support/D4 Plot/settings.json`
- Linux: `$XDG_CONFIG_HOME/d4-plot/settings.json`, or `~/.config/d4-plot/settings.json`
- Windows: `%APPDATA%\D4 Plot\settings.json`, then `%LOCALAPPDATA%\D4 Plot\settings.json`, then `~/D4 Plot/settings.json`

Invalid settings fall back to defaults.
