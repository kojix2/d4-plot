# d4-plot

A desktop viewer for D4 genomic signal, built with [UIng](https://github.com/kojix2/uing).

## Requirements

- Crystal 1.21 or later
- [Shards](https://github.com/crystal-lang/shards)
- Git
- The native GUI build and runtime dependencies required by UIng and libui-ng. On Linux this includes GTK 3 and Pango development libraries; on macOS install the Xcode Command Line Tools. See the [UIng installation guide](https://kojix2.github.io/uing/books/guide_en/installation.html) for platform details.

## Build and run

From a clean checkout:

```sh
git clone https://github.com/kojix2/d4-plot.git
cd d4-plot
shards install
shards build --release
bin/d4-plot
```

Open one or more D4 files, optionally at a region:

```sh
bin/d4-plot sample.d4
bin/d4-plot sample.d4 chr1:1,000,000-2,000,000
bin/d4-plot --region chr1:1,000,000-2,000,000 sample1.d4 sample2.d4
```

## Use

Opening a D4 file shows all its non-empty internal tracks. **Add D4…** appends another file; **Open** starts a new workspace. All tracks share one region. Choose a chromosome, enter a region, then click **Go**. Region input accepts `chr1:100-200`, `chr1:100`, or `chr1`. Coordinates are **1-based, inclusive**.

| Action | Control |
| --- | --- |
| Zoom | Zoom buttons, double-click to zoom in, right-click to zoom out |
| Move all tracks | Left / Right buttons, drag a signal, or click the chromosome overview |
| Manage tracks | Select a title or list item; use Show, Up / Down, or Remove |
| Compare tracks | Shared Y uses one automatic scale; Height changes row size |
| Scroll tracks | Scrollbar or mouse wheel over the plot |
| Select a range | Shift+drag across the signal |
| Restore a previous view | Back / Forward |
| Inspect values | Hover for the exact bin interval and mean |
| Keyboard navigation | Focus the plot, then use Left / Right, + / −, Home, or Esc |
| Resolution, Y scale and reference lines | Display |
| Toolbar and guidance | Icons only by default; **Show details** toggles annotation and navigation hints |

Dragging previews the new region; release to load it. Press **Esc** to cancel a drag or an active read.

The graph shows **bin means**, with the D4 denominator applied. Bin widths are shown in bp; narrow peaks can be hidden by averaging, so zoom in to inspect them. The region mean is weighted by bin width. Automatic Y scaling includes negative values; a fixed Y scale helps compare different regions. D4 signal is not assumed to be read depth or normalized between samples.

Load GFF3/GTF genes, transcripts and exons, or BED intervals using **Annotations**. Features use the same horizontal coordinates as the signal, with strand arrows and notices for missing chromosomes or hidden overlaps. BED records are shown as intervals; transcript models are not reconstructed. Use the same reference assembly and exact chromosome names: the viewer cannot infer or verify the assembly. For large annotations, use bgzip and tabix (`.tbi` / `.csi`); unindexed loading is limited to 32 MiB expanded text and 100,000 features.

**Export bins** saves the selected visible track's displayed means as bedGraph, using **0-based, half-open** coordinates. It exports the current display resolution, not the original per-base signal. These coordinate conventions follow [UCSC's description](https://genome-blog.soe.ucsc.edu/blog/2016/12/12/the-ucsc-genome-browser-coordinate-counting-systems/).

Use files from the same reference assembly. Tracks without the selected chromosome show an empty row; conflicting lengths for the same chromosome name are rejected. Reading runs in the background for visible tracks, with bounded buffers and only the latest pending navigation retained. Cancel keeps the last completed plot. Wide views use an embedded sum index when available.

For synthetic examples, run `crystal run examples/make_demo.cr`, then open `demo/control.d4` and add the other generated files.

## Development

```sh
crystal spec spec
crystal tool format --check src spec
```

## License

MIT. See [LICENSE](LICENSE). Test fixture attribution is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
