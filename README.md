# d4-plot

A desktop viewer for D4 signal files.

<img width="519" height="398" src="https://github.com/user-attachments/assets/4764c1b7-2147-476a-8e57-8da2e6cf81fb" />

## Requirements

- Crystal 1.21 or later, Shards, and Git
- Native GUI dependencies for [UIng](https://kojix2.github.io/uing/books/guide_en/installation.html): GTK 3 and Pango development packages on Linux, or Xcode Command Line Tools on macOS

## Build and run

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install
shards build --release
```

Run with one or more D4 files:

```sh
bin/d4-plot sample.d4
bin/d4-plot sample.d4 chr1:1,000,000-2,000,000
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
```

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

Export bins writes the selected visible track's displayed means as bedGraph (0-based, half-open), not the original per-base signal. Only visible tracks are read. Cancelling a read keeps the last completed plot.

Generate synthetic example files with `crystal run examples/make_demo.cr`; they are written to `demo/`.

## Development

```sh
crystal spec spec
crystal tool format --check src spec examples
```

## License

MIT. See [LICENSE](LICENSE). Test fixture attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
