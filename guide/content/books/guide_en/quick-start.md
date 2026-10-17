# Start here: a five-minute workflow

This is the shortest route from a D4 file to a useful view. D4 Plot is a
viewer: it helps you inspect and compare signal that has already been
calculated. It does not replace an alignment, variant-calling, or statistical
analysis pipeline.

## Before you open the application

You need one of these:

- a D4 file supplied by your analysis pipeline; or
- a coordinate-sorted BAM with a BAI/CSI index, or a CRAM with a CRAI index,
  if you want D4 Plot to create a D4 file for you. CRAM also needs the matching
  reference FASTA and its `.fai` index.

When comparing samples, confirm that the files were made against the same
reference assembly. D4 metadata does not record the assembly identity, so
matching chromosome names alone are not proof that two samples are
comparable.

## The basic workflow

1. Install a release package from [GitHub Releases](https://github.com/kojix2/d4-plot/releases).
   A normal user does not need Crystal, Shards, or a compiler.
2. Start D4 Plot and choose **Open D4**. Select one or more D4 files. If you
   only have BAM/CRAM, first choose **Create D4**, then **Add to view** after
   conversion finishes. See [Creating D4 files](creating-d4.md) for details.
3. Enter a location such as `chr1:100000-200000`, then choose **Go**. You can
   also enter a chromosome name to see the whole chromosome.
4. Select a track by clicking its title or selecting it in the track list.
   Use **Shared Y** when comparing the heights of signal across visible
   tracks; otherwise each track may use its own vertical scale.
5. Put the pointer over the signal to inspect a bin. The displayed value is
   the mean for that bin, not necessarily a value for one base. Zoom in when
   a narrow peak matters.

![Two synthetic D4 tracks with a gene annotation in the desktop viewer](../../screenshots/en/overview.png)

The example uses synthetic data; the two tracks share one Y scale.

The **Back**, **Forward**, **Zoom in**, **Zoom out**, and **Whole chromosome**
controls help you move between regions. Drag to pan; Shift-drag or right-drag
to select a range. The keyboard works when the plot has focus: Left and Right
pan, `+` and `-` zoom, Home shows the chromosome, and Escape cancels a load or
drag.

## The next useful actions

- Choose **Add D4** to add another sample without replacing the current view.
- Choose **Annotations** to display a matching GFF3, GTF, or BED file.
- Choose **Export bins** to save the selected track's displayed bin means as
  bedGraph.
- Choose **Save plot as SVG** to save the complete visible plot, including
  tracks below the vertical scroll position.

See [Viewing tracks](viewing-tracks.md) for how to read the display,
[Annotations and export](annotations-and-export.md) for files and coordinate
systems, and [Creating D4 files](creating-d4.md) when you start with BAM or
CRAM instead of D4.

## If something does not look right

- **A D4 file does not open:** check that you selected a completed, readable
  D4 file.
- **Creating D4 from BAM/CRAM fails:** check that the alignment is
  coordinate-sorted and has a matching index. CRAM also needs its matching
  reference FASTA and `.fai` index.
- **Tracks cannot be compared:** verify the reference assembly and exact
  chromosome names. A `chr1`/`1` difference is enough to prevent a match.
- **A peak looks flat:** the current view may combine many bases into one bin.
  Zoom in or increase the bin resolution in **Settings**.
- **The plot heights are misleading:** enable **Shared Y**, or set a fixed Y
  range when comparing separate regions.
