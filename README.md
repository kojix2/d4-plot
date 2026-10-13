# d4-plot

A desktop viewer for D4 genomic signal files. It can also create coverage D4 files from BAM or CRAM.

<img width="519" height="398" src="https://github.com/user-attachments/assets/4764c1b7-2147-476a-8e57-8da2e6cf81fb" />

## Requirements

- Crystal 1.21 or later, Shards, and Git
- [UIng native dependencies](https://kojix2.github.io/uing/books/guide_en/installation.html)
- HTSlib and pkg-config

On macOS, install the native dependencies with `brew install htslib pkg-config`. On Debian or Ubuntu, use `sudo apt install libhts-dev pkg-config`. Windows builds require MSYS2 UCRT64; see [.github/actions/setup-windows/action.yml](.github/actions/setup-windows/action.yml).

## Install

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

## Run

```sh
bin/d4-plot sample.d4
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
```

Supported interface languages are listed by `bin/d4-plot --help`. If `--locale` is omitted, the system language is used when available.

## Use

- Enter `chr1:100-200`, `chr1:100`, or `chr1`, then click **Go**.
- Drag to pan, Shift-drag to select, double-click to zoom in, and right-click to zoom out.
- Use **Add D4** to compare files. All files must use the same reference assembly.
- Use **Annotations** to load GFF3, GTF, or BED. Large files should be compressed with bgzip and indexed with tabix.
- Use **Export bins** to save the selected visible track as bedGraph.
- Use **Display** to change resolution, Y scale, colors, track height, and toolbar labels.

Coordinates shown by the viewer are 1-based and inclusive. Exported bedGraph coordinates are 0-based and half-open. Plots display the mean value of each bin, so zoom in to inspect narrow peaks.

## Create D4

Choose **Create D4** and provide:

- A coordinate-sorted BAM with BAI/CSI, or CRAM with CRAI
- For CRAM, the matching reference FASTA and `.fai`
- A new output filename ending in `.d4`

Coverage modes:

- **Standard:** respects CIGAR gaps and avoids double-counting overlapping mates
- **Fast:** counts complete read spans
- **Fragments:** counts proper paired-template spans

Existing output files are never overwritten. Creation runs in the background and can be cancelled safely.

## Development

```sh
crystal spec spec
ameba
crystal tool format --check src spec examples
```

Run the native UI smoke test in a graphical session:

```sh
crystal run scripts/ui-smoke.cr
```

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
