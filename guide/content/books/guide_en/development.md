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
