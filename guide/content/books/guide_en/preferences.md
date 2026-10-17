# Preferences and languages

D4 Plot saves the selected language and display preferences, including the
toolbar mode, track height, sidebar visibility, shared Y setting, bin count,
signal color, Y-axis settings, reference lines, and annotation limit.

## Useful settings

You can start with the defaults. These settings are the ones most likely to
change how you interpret a plot:

| Setting | When to use it |
| --- | --- |
| **Bin count** | Increase it after zooming in when you need finer detail; fewer bins make a wide overview easier to read. |
| **Automatic Y scale** | Find the shape of a signal quickly. |
| **Fixed Y scale** | Compare several regions or make figures with the same vertical limits. |
| **Include zero** | Keep the baseline visible when the absolute height matters. |
| **Shared Y** | Compare absolute heights between visible tracks. |
| **Track height** and **sidebar** | Make labels easier to read or give the plot more room. |
| **Reference lines** | Mark a threshold or other value that matters to your experiment. |

Changing the display settings does not change the D4 files. It changes how
the signal is shown or exported.

## Language

The language can be changed in **Settings**. Restart D4 Plot after changing it.
The command-line `--locale` option is useful when a lab computer is shared or
when you need one temporary language for a screenshot or support report.

## Where settings are stored

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
