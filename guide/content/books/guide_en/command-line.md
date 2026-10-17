# Command-line usage (advanced)

Most researchers can skip this page and use the desktop application. These
commands are useful for lab automation, shared workstations, local browser
viewing, or IT staff supporting an installation.

D4 Plot has two command-line entry points:

- `d4-plot` starts the native desktop application.
- `d4-plot serve` and `d4-plot-server` start the local IGV.js viewer without
  the native desktop UI.

Run either executable with `--help` to print its available options. Paths may
be absolute or relative to the current directory.

## Desktop application

Open one or more D4 files:

```sh
d4-plot sample.d4
d4-plot sample1.d4 sample2.d4
```

The first form opens the files. In the application, **Open D4** replaces the
current tracks, while **Add D4** appends tracks to the current view.

Start at a region with 1-based, inclusive coordinates:

```sh
d4-plot --region chr1:1,000,000-2,000,000 sample.d4
```

The same syntax is accepted by the region field in the application. A single
position such as `chr1:100` and a chromosome name such as `chr1` are also
valid when the chromosome is present in the loaded D4 files. Commas are
allowed in coordinates.

Choose the interface language for one run with `--locale`:

```sh
d4-plot --locale ja sample.d4
```

The command-line locale takes precedence over the saved preference. Without
it, D4 Plot uses the saved setting, or the operating-system language when the
setting is **System default**. See [Preferences and languages](preferences.md)
for the language setting and its file location.

## Local browser viewer

The `serve` subcommand and the standalone `d4-plot-server` executable accept
the same options. They print a token-scoped URL and keep serving until you
press Ctrl-C:

```sh
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --genome hg38 --open
```

Use `--open` to launch the default browser automatically. If it cannot be
launched, the server remains running and the printed URL can be opened
manually. The server listens only on `127.0.0.1`; open the URL on the same
computer and do not share it because it contains a session token.

### Reference selection

The server accepts at most one of these reference choices:

| Option | Meaning |
| --- | --- |
| `--genome ID` | Use an IGV public preset such as `hg38`. |
| `--reference PATH` | Use a local FASTA or an IGV genome JSON file. |
| `--contigs-only` | Use only the chromosome names and lengths from the D4 files. |

A local FASTA must have a matching `.fai` index. Use `--reference-index` when
the index is not next to the FASTA:

```sh
d4-plot-server --reference reference.fa \
  --reference-index indexes/reference.fa.fai sample.d4
```

For an IGV genome JSON file, the referenced local files must be accessible
from the machine running the browser. `--reference-index` cannot be used with
JSON references.

When a D4 file is supplied without another reference choice, the viewer can
use its contig dictionary as **Contigs only**. This provides names and lengths,
not sequence bases, and does not prove which reference assembly produced the
D4 file. Without a D4 file, provide `--genome` or `--reference`.

Public presets download reference data from the configured public hosts in the
browser. Use a local FASTA and FAI when reference access must remain local.
See [IGV integration](igv-integration.md) for the effect on added tracks and
CRAM data.

### Server options

| Option | Meaning |
| --- | --- |
| `--region REGION` | Initial locus, for example `chr1:100-200`. |
| `--locale LOCALE` | Language used by the browser viewer. |
| `--port PORT` | Loopback port; `0` chooses an available port. |
| `--open` | Open the viewer URL after startup. |
| `--help` | Print usage and exit. |

For example, start a local viewer with a FASTA reference and an initial
region:

```sh
d4-plot serve --reference reference.fa --region chr1:100-200 --locale en --open
```

The server accepts D4 paths after the options. If no D4 path is supplied,
`--genome` or `--reference` is still required. `--genome`, `--reference`, and
`--contigs-only` are mutually exclusive, and `--reference-index` requires
`--reference`.

On Windows, run `d4-plot-server` from a terminal when you need to copy the
printed URL. In the macOS application bundle, the standalone executable is at
`d4-plot.app/Contents/MacOS/d4-plot-server`.
