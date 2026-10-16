# Annotations and export

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
the bins in the completed view as bedGraph. This is a sampled display export,
not the original per-base signal.

The output contains the source path and track name in comments. Intervals are
0-based and half-open, while coordinates shown in the application are 1-based
and inclusive. D4 Plot refuses to use an input D4 or the current annotation as
the export destination.

## Saving a plot image

Choose **Save plot as SVG** from the File menu to save the current region as an
SVG image. The image includes every visible track and its annotations, even
rows outside the scrolled viewport. SVG remains sharp when enlarged. The
`.svg` extension is added when omitted.
