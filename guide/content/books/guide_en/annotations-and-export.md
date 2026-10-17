# Annotations and export

## A practical workflow

1. Open a D4 file and navigate to the region you want to inspect.
2. Choose **Annotations** and select a GFF3, GTF, or BED file made for the
   same reference assembly.
3. If nothing appears, first check the chromosome spelling and the current
   region. A file for `1` will not appear on a D4 track named `chr1`.
4. For a figure, hide unrelated tracks, choose a useful zoom level, and use
   **Save plot as SVG**. For numerical follow-up, use **Export bins** and keep
   the D4 file and the export settings with the result.

## Annotations

Choose **Annotations** to open GFF3, GTF, or BED data from the same reference
assembly as the D4 tracks. Chromosome names must match exactly, including any
`chr` prefix.

For GFF3 and GTF, D4 Plot displays gene, transcript, mRNA, and exon features.
BED intervals are also supported. Plain files and gzip-compressed files can be
loaded into memory, subject to limits of 32 MiB and 100,000 parsed features.

For larger data, compress the file with bgzip and create a tabix `.tbi` or
`.csi` index. A `.gz` file with either index is queried directly through
HTSlib; D4 Plot does not invoke the `tabix` command.

## Exporting visible bins

Select a visible track and choose **Export bins**. D4 Plot writes the means of
the bins in the completed view as bedGraph. The desktop viewer calculates the
mean over each bin's interval. Variation within a wide bin is lost in the
export, so the result is not the original per-base signal.

The output contains the source path and track name in comments. Intervals are
0-based and half-open, while coordinates shown in the application are 1-based
and inclusive. D4 Plot refuses to use an input D4 or the current annotation as
the export destination. Check the source path in the comments before sharing
the bedGraph file.

Because the export follows the current view, change the region and bin count
before exporting if you need a different resolution. It is not a replacement
for the original per-base or read-level data.

## Saving a plot image

Choose **Save plot as SVG** from the File menu to save the current region as an
SVG image. The image includes every visible track and its annotations, even
rows outside the scrolled viewport. SVG remains sharp when enlarged. The
`.svg` extension is added when omitted.
