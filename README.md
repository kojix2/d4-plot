# d4-plot

[![build](https://github.com/kojix2/d4-plot/actions/workflows/build.yml/badge.svg)](https://github.com/kojix2/d4-plot/actions/workflows/build.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fd4-plot%2Flines)](https://tokei.kojix2.net/github/kojix2/d4-plot)
[![DOI](https://zenodo.org/badge/1413919809.svg)](https://doi.org/10.5281/zenodo.23444683)

A native desktop viewer for D4 genomic signal files. D4 Plot compares multiple
tracks, displays genomic annotations, exports visible bins, and creates coverage
D4 files from BAM or CRAM.

<img width="600" src="https://kojix2.github.io/d4-plot/screenshots/en/overview.png" alt="Two tracks from spec/fixtures/rust-multitrack.d4 in D4 Plot" />

## Documentation

[English guide](https://kojix2.github.io/d4-plot/books/guide_en/) ·
[日本語ガイド](https://kojix2.github.io/d4-plot/books/guide_ja/)

## Install

Download a package from [GitHub Releases](https://github.com/kojix2/d4-plot/releases),
or follow the [source build guide](https://kojix2.github.io/d4-plot/books/guide_en/installation.html).

## Browser viewer / headless server

Open the bundled local IGV.js viewer with or without D4 tracks, without starting
the native desktop UI:

```sh
# Either entry point accepts the same options.
d4-plot serve --genome hg38 --open sample.d4
d4-plot-server --genome hg38 --open
d4-plot-server --reference reference.fa --reference-index reference.fa.fai sample.d4
d4-plot-server --contigs-only sample.d4
```

The server binds only to `127.0.0.1` and prints a token-scoped viewer URL. Use
`--open` to launch it automatically, or paste the printed URL into a browser.
`--port 0` (the default) selects an available loopback port; stop the server
with Ctrl-C. On Windows, run `d4-plot-server` from a terminal when you need to
copy the printed URL. In the macOS DMG, the standalone binary is inside the
application bundle at `d4-plot.app/Contents/MacOS/d4-plot-server` so it can
share the bundle's packaged native libraries.

Reference choices are mutually exclusive: `--genome ID`, `--reference PATH`,
or `--contigs-only`. A local FASTA requires an existing FAI (use
`--reference-index` to name a non-default one). A `.json` reference is treated
as an IGV genome JSON and its referenced files must be accessible local files.
Preset genomes use IGV's public reference definitions, so their sequence data
is not available offline unless a local reference is supplied. With a preset,
the browser fetches public reference data directly from IGV/UCSC hosts; the
local server does not proxy those requests. Those HTTPS byte-range requests
can reveal the reference and approximate viewed genomic intervals to that
reference host; use a local FASTA/FAI for fully local reference access.

## Development

```sh
shards install --frozen
crystal spec spec
ameba
crystal tool format --check src spec examples
```

See the [development guide](https://kojix2.github.io/d4-plot/books/guide_en/development.html)
for native dependencies, platform-specific builds, and UI runtime constraints.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
