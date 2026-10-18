# Annotations and export

## Annotations

Choose **Annotations** to open GFF3, GTF, or BED for the same reference assembly as the D4. Chromosome names must match exactly (`1` differs from `chr1`). GFF3/GTF display gene, transcript, mRNA, and exon features.

Plain or gzip files can be loaded into memory up to 32 MiB and 100,000 parsed features. For larger files, use bgzip with a tabix `.tbi` or `.csi` index. Indexed `.gz` files are queried through HTSlib.

## Export bins

Select a visible track and choose **Export bins**. The bedGraph contains means for the current display bins, not the original per-base values. Set the region and bin count before exporting.

bedGraph intervals are **0-based and half-open**; viewer coordinates are **1-based and inclusive**. Output comments include the source path and track name, so inspect them before sharing. The export cannot overwrite an input D4 or the current annotation.

## Save SVG

Choose **File → Save plot as SVG**. The image includes all visible tracks and annotations, including rows outside the scrolled viewport. The `.svg` extension is added if omitted.
