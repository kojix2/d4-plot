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

On macOS, build the Nicolino site, then run from the repository root:

```sh
mkdir -p guide/output/screenshots
crystal run scripts/guide-screenshots.cr -- guide/output/screenshots/en en
crystal run scripts/guide-screenshots.cr -- guide/output/screenshots/ja ja
```

The language directories must not exist before running the script. It reads `spec/fixtures/rust-multitrack.d4` and creates a BED annotation and BAM input. The docs workflow captures both languages on macOS and adds them to the Pages build.

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
