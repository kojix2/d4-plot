# Development

Install the native dependencies described in [Installation](installation.md),
then run the checks used during development:

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

The CI workflow runs specs and release builds on Ubuntu, macOS, and Windows
UCRT64. Run the native UI smoke test in a graphical session:

```sh
crystal run scripts/ui-smoke.cr
```

To change the application icon, replace `assets/d4-plot.png` with a square PNG
that has a transparent background, then run `bash scripts/refresh-icons.sh`
with ImageMagick installed. The macOS icon is generated while packaging the app
bundle.

## Diagnostic logs

D4 Plot uses Crystal's standard `Log` library. `INFO` is the default; set
`LOG_LEVEL=DEBUG` before launching to include read strategy, cache hits, request
cancellation, paths, genomic regions, and exception backtraces. `LOG_LEVEL=NONE`
disables application diagnostics. Invalid levels fall back to `INFO` with a warning.

The desktop app writes to `d4-plot-<process-id>.log` in:

- Windows: `%LOCALAPPDATA%\D4 Plot\logs` (then `%APPDATA%`, then the home directory).
- macOS: `~/Library/Logs/D4 Plot`.
- Linux: `$XDG_STATE_HOME/d4-plot/logs`, or `~/.local/state/d4-plot/logs`.

`d4-plot serve` and `d4-plot-server` write logs to stderr. The viewer URL and help
remain on stdout. Set `D4_PLOT_LOG_FILE` to write either entry point's logs to a
chosen file. Use a different path for each simultaneously running process.
Files rotate at approximately 5 MiB, keeping two backups (`.1` and `.2`), or
approximately 15 MiB per process/file path. Old process logs are retained until
you remove them; the directory has no aggregate size limit. If a log file cannot
be opened, logging falls back to stderr.

For example, in PowerShell:

```powershell
$env:LOG_LEVEL = 'DEBUG'
$env:D4_PLOT_LOG_FILE = "$env:TEMP\d4-plot-debug.log"
.\bin\d4-plot.exe
# After reproducing the problem, close the app to drain pending log entries.
Remove-Item Env:LOG_LEVEL, Env:D4_PLOT_LOG_FILE
```

Each entry contains a timestamp, severity, process ID, source, stable event name,
and metadata. Follow `request_id` for file/view reads and HTTP requests, or
`job_id` for conversions and background writes. Generated IDs are unique within
a process. HTTP responses include `X-Request-ID` to locate the corresponding
server entry. Ordinary error entries contain the exception class; DEBUG entries
include an exception and backtrace snapshot captured on the failing thread.
Review DEBUG logs before sharing because they can contain file paths, track names,
and genomic coordinates. Viewer capability URLs are omitted/redacted from the
application logs; the URL printed to stdout is still a working access link.

The logging dispatcher uses a bounded queue and native synchronization so UI
callbacks never yield waiting for log delivery or perform log file I/O. At
capacity it drops new entries and later reports `log.entries_dropped`. Write
failure disables that output and emits a best-effort stderr notice. Shutdown
drains accepted entries after UI teardown; forced termination can lose pending
entries. No per-base/per-bin or paint/mouse-move logs are emitted.

## Native UI runtime

The application runs `UIng.main` on the native UI thread and polls worker
results every 30 ms. Native callbacks must not perform filesystem I/O, sleep,
wait on channels, or join workers: a yielding Crystal operation can resume on a
different OS thread.

Capture immutable data and submit background writes through `BackgroundIO`;
apply their completions from its `poll` method. Startup reads use
`UIRuntime.load` before windows are created. That helper blocks the current OS
thread and must not be called from a UI callback. Accepted writes are drained
after native UI teardown.

`BackgroundIO` uses a `Concurrent` execution context. HTTP calls to IGV
Desktop run there; only their results are applied by `poll` on the UI thread.
Especially on macOS, do not touch UIng controls from a fiber doing network
I/O. HTTP responses do not always have a body: an IGV Desktop 204 response,
for example, must be accepted without reading `body_io`.
