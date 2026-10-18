# Command-line usage

Run `d4-plot --help` or `d4-plot-server --help` for all options. Paths may be absolute or relative to the current directory.

## Desktop

```sh
d4-plot sample.d4
d4-plot sample1.d4 sample2.d4
d4-plot --region chr1:1,000,000-2,000,000 sample.d4
d4-plot --locale ja sample.d4
```

Regions use 1-based, inclusive coordinates. `chr1:100` selects one base; `chr1` selects the chromosome. `--locale` overrides the saved language for one run.

## Browser server

`d4-plot serve` and `d4-plot-server` accept the same options:

```sh
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --genome hg38 --open
d4-plot-server --reference reference.fa --reference-index reference.fa.fai sample.d4
```

The server prints a token URL, binds to `127.0.0.1`, and runs until Ctrl-C. Open the URL on the same computer; do not share it. `--open` launches the browser, but failure to launch it does not stop the server.

Choose at most one reference mode:

| Option | Reference |
| --- | --- |
| `--genome ID` | Public IGV preset, such as `hg38`. |
| `--reference PATH` | Local FASTA or IGV genome JSON. FASTA requires a `.fai`; use `--reference-index PATH` for a different location. |
| `--contigs-only` | Names and lengths from D4, without sequence bases. |

With a D4 file and no reference option, the server uses its contigs. Without a D4 file, specify `--genome` or `--reference`. A D4 contig dictionary does not establish the source assembly. Public presets fetch reference data from public hosts; use a local FASTA/FAI to keep reference access local. A JSON reference must point to files accessible from the browser.

| Option | Use |
| --- | --- |
| `--region REGION` | Initial locus, such as `chr1:100-200`. |
| `--locale LOCALE` | Browser language. |
| `--port PORT` | Loopback port; `0` selects an available port. |
| `--open` | Open the URL after startup. |

On Windows, run `d4-plot-server` in a terminal to copy the URL. In the macOS bundle, it is at `d4-plot.app/Contents/MacOS/d4-plot-server`. See [IGV integration](igv-integration.md) for track and reference behavior.
