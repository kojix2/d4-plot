# Viewing tracks

## Opening files

**Open D4** replaces the current tracks and annotation. **Add D4** keeps the
current view and appends tracks. Both file dialogs accept multiple files, and
each track contained in a D4 file is added separately.

File metadata is checked in the background before the new selection is
applied. Cancelling or encountering an invalid file keeps the previous view.
Files may have different chromosome sets, but a chromosome appearing in more
than one track must have the same length.

D4 metadata does not establish which reference assembly produced a file.
Matching chromosome names and lengths are therefore not proof that tracks use
the same assembly; verify their provenance before comparison.

## Before comparing tracks

Before comparing two samples, check these three things:

1. They were aligned to the same reference assembly, such as hg38 or GRCh38.
2. They use comparable filtering and normalization. D4 Plot does not
   automatically normalize tracks just because they are displayed together.
3. Their chromosome names use the same convention, for example `chr1` versus
   `1`.

If you are unsure, keep the sample information or the command used to create
each D4 file with the file. This information is more reliable than the D4
metadata alone.

## Reading the signal

D4 Plot summarizes the signal in display bins. At a wide view, one visual
column can represent many bases; after zooming in, the bins become smaller.
For a coverage D4, the value is the mean coverage in the bin, not necessarily
the number of reads at one particular base. A narrow peak can therefore look
lower or wider when you change the zoom level.

Use **Shared Y** when the height of one sample should be directly compared with
another. Use separate automatic scales when you are looking for the shape of
each sample rather than its absolute height. A fixed Y scale is useful when you
want the same limits across several regions or exported figures.

![Closer view of two synthetic D4 tracks and their display bins](../../screenshots/en/inspect.png)

The closer view shows the same synthetic samples after narrowing the region.

## Regions and navigation

The region field accepts:

- `chr1:100-200` for a range;
- `chr1:100` for one base; or
- `chr1` for the whole chromosome.

Use the mouse or toolbar to navigate:

- drag to pan;
- Shift-drag or right-drag to select a range;
- double-click to zoom in;
- right-double-click to zoom out;
- click outside the highlighted chromosome-overview range to recenter the view;
- use **Back** and **Forward** to revisit regions.

When the plot has keyboard focus, Left and Right pan by half a view, `+` and
`-` zoom, Home shows the whole chromosome, and Escape cancels a drag or an
active load.

## Managing the display

Select a track by its title or in the track list. The list can show, hide,
reorder, or remove tracks without deleting their files. **Shared Y** gives all
visible tracks one scale. **Height** changes track row height, and the track
sidebar can be hidden to give the plot more space.

The **Settings** window controls the number of bins, automatic or fixed Y scale,
whether automatic scaling includes zero, reference lines, signal color,
annotation limit, and toolbar labels.

See [IGV integration](igv-integration.md) to send the current locus to IGV
Desktop or view D4 tracks in IGV.js.
