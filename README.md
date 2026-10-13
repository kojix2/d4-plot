# d4-plot

A desktop viewer for D4 signal files, with BAM / CRAM to D4 coverage creation.

<img width="519" height="398" src="https://github.com/user-attachments/assets/4764c1b7-2147-476a-8e57-8da2e6cf81fb" />

## Requirements

- Crystal 1.21 or later, Shards, and Git
- Native GUI dependencies for [UIng](https://kojix2.github.io/uing/books/guide_en/installation.html): GTK 3 and Pango development packages on Linux, or Xcode Command Line Tools on macOS
- HTSlib and pkg-config: `brew install htslib pkg-config` on macOS, or `sudo apt install libhts-dev pkg-config` on Debian/Ubuntu
- Windows builds use **MSYS2 UCRT64 (MinGW)**, not MSVC. HTSlib and the GUI library must use the same ABI. See [.github/actions/setup-windows/action.yml](.github/actions/setup-windows/action.yml) for the package list; run `shards install --frozen` then `bash scripts/build-windows.sh` in a UCRT64 shell. This builds pinned, local-only HTSlib and tests before producing a static GUI executable.

## Build and run

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install --frozen
shards build --release
```

Run with one or more D4 files:

```sh
bin/d4-plot sample.d4
bin/d4-plot sample.d4 chr1:1,000,000-2,000,000
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
bin/d4-plot --locale ja sample.d4
bin/d4-plot --locale fr sample.d4
bin/d4-plot --locale pt-BR sample.d4
```

## Language

The interface is available in English, Japanese, Simplified Chinese, Spanish, German, French, Korean, Dutch, Portuguese, Polish, Turkish, Russian, Hindi, Indonesian, Urdu, Vietnamese, Hebrew, Arabic, and Bengali. By default, d4-plot uses the system locale when it is supported; use `--locale en|ja|zh|es|de|fr|ko|nl|pt|pl|tr|ru|hi|id|ur|vi|he|ar|bn` to choose explicitly. Regional locale names such as `pt-BR` are accepted and use the matching language catalogue.

Translations are maintained in [config/locales](config/locales), using [crystal-i18n](https://github.com/crystal-i18n/i18n). They are embedded at build time, so release packages do not depend on their launch directory or separately installed locale files.

## Use

Opening a file shows all its non-empty internal tracks. Open replaces the current set; Add D4 appends a file. All tracks use the same region.

- Enter `chr1:100-200`, `chr1:100`, or `chr1` and click Go. Coordinates are 1-based and inclusive.
- Drag a plot to pan, Shift-drag to select a range, double-click to zoom in, or right-click to zoom out. Back and Forward restore previous regions. Esc cancels a drag or read.
- Select a track by its title or the track list. Show, Up, Down, and Remove manage tracks. Scroll vertically with the scrollbar or mouse wheel; Height changes row size.
- Display controls bin count, Y scale, reference lines, and toolbar labels. Shared Y gives visible tracks one automatic scale. Show details displays the selected source path and denominator.
- Hover over a plot to inspect a bin. Gray areas during a drag preview have not been read.

Plots show means per bin after applying the D4 denominator. Zoom in to inspect narrow peaks. Shared Y does not normalize samples; fixed Y limits apply to all tracks.

Use files from the same reference assembly and match chromosome names exactly. Tracks missing the selected chromosome show an empty row; conflicting lengths for the same chromosome name are rejected. Matching names and lengths do not establish assembly compatibility.

Use Annotations to load GFF3, GTF, or BED. For large files, use bgzip and tabix (`.tbi` or `.csi`); unindexed input is limited to 32 MiB expanded text and 100,000 features.
Loading annotations does not open Show details. A failed replacement keeps the previous annotation selection; its error is available by hovering over the annotation status. The annotation lane keeps the same height when navigating through empty or dense regions.

Export bins writes the selected visible track's displayed means as bedGraph (0-based, half-open), not the original per-base signal. Only visible tracks are read. Cancelling a read keeps the last completed plot.

Generate synthetic example files with `crystal run examples/make_demo.cr`; they are written to `demo/`.

## Create D4

Choose **Create D4** in the toolbar, File menu, or empty view. Conversion runs independently of viewing; closing its window keeps it running and reopening restores its settings and status. Only one creation can run at a time.

- Input: a local, coordinate-sorted BAM with BAI/CSI, or CRAM with CRAI. CRAM also requires an explicitly selected matching FASTA and its `.fai`. The app does not sort alignments or create missing input indexes.
- Output: a new `.d4` filename. Existing files are never overwritten, including files created by another process while conversion is running. Temporary output is created in the destination folder and removed on cancellation or failure. Final publication uses a same-filesystem hard link; the destination filesystem must support hard links (for example, NTFS, APFS, ext4; not FAT/exFAT).
- Standard coverage respects CIGAR gaps and corrects overlapping mates. Fast counts complete read spans without overlap correction. Fragments counts proper paired-template spans, including the insert.
- Minimum MAPQ is available directly. Advanced options include decompression threads, SAM include/exclude flags, comma-separated read groups, and minimum/maximum absolute template length. Modified advanced settings are indicated even when collapsed. Template-length filters apply in every mode; supplementary alignments are not excluded by the default flags.

The output contains per-base coverage for every reference in the alignment header, including zero-coverage regions, and a secondary-frame index. No mopdepth CLI process, bedGraph intermediate, or summary sidecars are used. d4-plot uses mopdepth's public `Reader` API and d4.cr's public writer-control API; it does not import either project's internal implementation files.

Progress reports the current stage, reference, records read and elapsed time, not an estimated percentage. Cancellation is cooperative during alignment reading, dense-coverage preparation, D4 finalization, and index construction. Closing the main app while creating asks whether to cancel and quit. Memory usage includes an Int32 coverage buffer (roughly 4 bytes per base of the longest reference, plus writer and read data).

On success, **Add to view** is an explicit action. It keeps the current region, tracks, annotations and navigation history when compatible. Check the reference assembly yourself: matching sequence names and lengths are necessary but do not establish assembly identity. **Create another…** keeps the settings for another run; select a new output filename.

## Development

```sh
crystal spec spec
crystal tool format --check src spec examples
```

`spec/conversion_spec.cr` generates small BAM/CRAM fixtures and covers coverage modes, filtering, safe publication, cancellation and worker recovery. Run `crystal run scripts/ui-smoke.cr` in a graphical session for native UI regression checks. On macOS, optionally pass a **new** screenshot directory after `--`; captures use the application's individual window IDs, never the entire screen:

```sh
crystal run scripts/ui-smoke.cr -- /tmp/d4-plot-ui-check
```

## License

MIT. See [LICENSE](LICENSE). Dependency and test-fixture attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Release packages include dependency license texts.
