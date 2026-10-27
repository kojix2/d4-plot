# Development

Install the native dependencies in [Installation](installation.md), then run:

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

CI builds on Ubuntu, macOS, and Windows UCRT64. Run the UI smoke test in a graphical session:

```sh
crystal run scripts/ui-smoke.cr
```

To update the icon, replace `assets/d4-plot.png` with a square transparent PNG and run `bash scripts/refresh-icons.sh` with ImageMagick installed. Packaging generates the macOS icon.

## Guide screenshots

The build workflow captures the desktop executable it has just built on Windows,
macOS, and Linux with `kojix2/window-screenshot-action@main`. Screenshot scenes run
inside the regular `d4-plot` binary; no separate screenshot application is compiled.
The docs workflow is called after those builds and generates the site from their
image artifacts without installing Crystal or compiling the application again.

Each platform produces English and Japanese overview, inspection, and D4 creation
images under `screenshots/<windows|macos|ubuntu>/<en|ja>/`. The README and guide
display them in comparison tables.

The screenshot mode reads `spec/fixtures/rust-multitrack.d4` from the repository
root and generates temporary BED and BAM files. It reveals the target window only
after the view is ready; the action captures that window and stops the process.

To preview scenes with an already-built executable in a graphical session, run
from the repository root:

```sh
D4_PLOT_SCREENSHOT_SCENE=overview bin/d4-plot
D4_PLOT_SCREENSHOT_SCENE=inspect D4_PLOT_SCREENSHOT_LOCALE=ja bin/d4-plot
D4_PLOT_SCREENSHOT_SCENE=create-d4 bin/d4-plot
```

On Windows, set these environment variables in PowerShell and run
`bin/d4-plot.exe`. For argument-free action launches, copies of the same executable
named `guide-overview`, `guide-inspect`, and `guide-create-d4` select the scene with
`D4_PLOT_SCREENSHOT_SCENE=auto`. Normal startup is unchanged when the variable is
unset.

## Logs

Set `LOG_LEVEL=DEBUG` for read strategy, cache, cancellation, paths, coordinates, and backtraces; `LOG_LEVEL=NONE` disables diagnostics. Default is `INFO`. Desktop logs are `d4-plot-<process-id>.log` in:

- Windows: `%LOCALAPPDATA%\D4 Plot\logs`, then `%APPDATA%`, then home
- macOS: `~/Library/Logs/D4 Plot`
- Linux: `$XDG_STATE_HOME/d4-plot/logs`, or `~/.local/state/d4-plot/logs`

The server writes logs to stderr; its URL and help go to stdout. `D4_PLOT_LOG_FILE` selects a file for either executable. Logs rotate near 5 MiB with two backups. Old process logs remain until removed. If a log file cannot be opened, output falls back to stderr.

Use `request_id` for reads and HTTP, `job_id` for conversions and background writes. HTTP responses carry `X-Request-ID`. DEBUG logs may contain paths, track names, and coordinates; review them before sharing. Capability URLs are omitted from logs, but a URL printed to stdout remains usable.

The bounded logging queue drops new entries when full and reports `log.entries_dropped`. Shutdown drains accepted entries; forced termination can lose pending entries.

## UI thread

`UIng.main` runs on the native UI thread and polls worker results every 30 ms. Native callbacks must not perform file I/O, sleep, wait on channels, or join workers; a yielding fiber may resume on another OS thread.

Use `UIRuntime.load` for startup reads before creating windows. Submit writes and IGV Desktop HTTP calls through `BackgroundIO`; apply results from `poll` on the UI thread. Wait for accepted writes after native UI teardown. An IGV Desktop HTTP 204 response has no body and must be handled without reading `body_io`.
