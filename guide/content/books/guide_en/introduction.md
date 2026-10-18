# Introduction

D4 Plot displays [D4](https://github.com/38/d4-format) genomic signals. You can compare tracks, add GFF3/GTF/BED annotations, export bedGraph or SVG, and create coverage D4 files from BAM/CRAM.

Start with [Start here](quick-start.md).

## Reading the plot

Each plotted value is the mean for a display bin, after applying any scale stored in the D4. Zoom in to inspect narrow peaks; a wide bin can hide variation.

Before comparing tracks, confirm their reference assembly, chromosome names, and data processing. D4 files do not identify their source assembly. Use **Shared Y** when comparing signal heights.

Viewer coordinates are **1-based and inclusive**: `chr1:100-200` spans 101 bases. Exported bedGraph intervals are **0-based and half-open**.
