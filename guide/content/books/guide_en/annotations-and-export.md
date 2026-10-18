# Annotations and export

## Annotations

Choose a public genome at the beginning of the row with **Chromosome**, **Region**, and **Go** to display genes for hg38/GRCh38, hg19/GRCh37, hs1/T2T-CHM13, mm39/GRCm39, mm10/GRCm38, rn7 (rat), danRer11 (zebrafish), dm6 (fruit fly), ce11 (worm), or sacCer3 (yeast). Choose **Annotations** in the toolbar to open a local GFF3, GTF, or BED file directly. Public genes and the local file can appear in separate rows at the same time. Public genes show transcripts and their exons. **Settings → Public gene source** selects UCSC (the default) or Ensembl. UCSC uses `knownGene` for hg38, hg19, mm39, and mm10, and `ncbiRefSeq` for the other presets. Ensembl uses its own gene models and its GRCh37 service for hg19. Ensembl is supported for hg38, hg19, and mm39 here; the other presets show a notice and require UCSC. The public row names the source in both the desktop view and SVG. An internet connection is required, and each region is fetched again. If the request fails, the public row shows an error while the local annotation remains visible.

No public genome is selected by default. A new **Open D4** clears both annotation selections; **Add D4** keeps them. D4 does not identify its reference assembly, so select the matching public genome yourself. Conventional names such as `1` and `chr1` are mapped for public genes. Local files still require exact chromosome names (`1` differs from `chr1`). GFF3/GTF display gene, transcript, mRNA, and exon features.

Plain or gzip files can be loaded into memory up to 32 MiB and 100,000 parsed features. For larger files, use bgzip with a tabix `.tbi` or `.csi` index. Indexed `.gz` files are queried through HTSlib.

## Export bins

Select a visible track and choose **Export bins**. The bedGraph contains means for the current display bins, not the original per-base values. Set the region and bin count before exporting.

bedGraph intervals are **0-based and half-open**; viewer coordinates are **1-based and inclusive**. Output comments include the source path and track name, so inspect them before sharing. The export cannot overwrite an input D4 or the current annotation.

## Save SVG

Choose **File → Save plot as SVG**. The image includes all visible tracks and annotations, including rows outside the scrolled viewport. The `.svg` extension is added if omitted.
