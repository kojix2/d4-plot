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

The interface language can also be selected under **Display**. Language changes
take effect the next time D4 Plot starts. **System default** follows the OS
language: macOS uses the user's preferred languages, Windows uses the user
locale, and Linux uses `LC_ALL`, `LC_MESSAGES`, `LANGUAGE`, or `LANG`.
`--locale` overrides both the saved choice and the system language for that run.

Language and display preferences are kept in the standard per-user configuration
location, shared by portable and installed builds. Toolbar labels, track height,
shared Y scale, colors, resolution, fixed axis limits, reference lines, and the
annotation limit are restored on the next launch:

- macOS: `~/Library/Application Support/D4 Plot/settings.json`
- Linux: `$XDG_CONFIG_HOME/d4-plot/settings.json`, or `~/.config/d4-plot/settings.json`
- Windows: `%APPDATA%\D4 Plot\settings.json` (falling back to `%LOCALAPPDATA%`)

## Use

- Enter `chr1:100-200`, `chr1:100`, or `chr1`, then click **Go**.
- Drag to pan, Shift-drag to select, double-click to zoom in, and right-click to zoom out.
- Select multiple files at once with **Open D4** or **Add D4**. **Open D4** replaces the current tracks and annotations; **Add D4** keeps them and appends new tracks. All files must use the same reference assembly.
- Select tracks in the left-hand list. Use the checkboxes to show or hide them, **Up** / **Down** to reorder them, and **Remove from view** to remove them without deleting files.
- Use **Hide tracks** / **Show tracks** above the plot to toggle the sidebar and give the plot more space. The sidebar preference is restored on the next launch.
- File checks run in the background with progress and cancellation. Cancelling or encountering an invalid file leaves the previous view intact; the selected files are applied together after validation.
- Use **Annotations** to load GFF3, GTF, or BED. Large files should be compressed with bgzip and indexed with tabix.
- Indexed annotations (`.gz` with `.tbi` or `.csi`) are read directly through hts.cr / HTSlib; the viewer does not invoke the `tabix` command.
- Use **Export bins** to save the selected visible track as bedGraph.
- Use **Display** to change resolution, Y scale, colors, and toolbar labels. Use **Height** above the plot to change track height. The toolbar shows icons with labels by default.

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
