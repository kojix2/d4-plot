# Preferences and languages

D4 Plot saves the selected language and display preferences, including the
toolbar mode, track height, sidebar visibility, shared Y setting, bin count,
signal color, Y-axis settings, reference lines, and annotation limit.

The settings file is stored at:

- macOS: `~/Library/Application Support/D4 Plot/settings.json`
- Linux: `$XDG_CONFIG_HOME/d4-plot/settings.json`, or
  `~/.config/d4-plot/settings.json`
- Windows: `%APPDATA%\D4 Plot\settings.json`; if unavailable,
  `%LOCALAPPDATA%\D4 Plot\settings.json`, then `~/D4 Plot/settings.json`

A damaged or partially obsolete settings file does not prevent startup;
invalid fields fall back to defaults.

The **System default** language follows the operating system preference on
macOS and Windows. On Linux it checks `LC_ALL`, `LC_MESSAGES`, `LANGUAGE`, then
`LANG`. Unsupported languages fall back to English. A saved language overrides
the system choice, and `--locale` overrides both for that run. A language
changed in **Settings** takes effect after restarting D4 Plot.
